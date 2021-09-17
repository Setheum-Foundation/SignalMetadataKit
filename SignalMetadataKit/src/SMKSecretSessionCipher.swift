//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import Foundation
import Curve25519Kit
import SignalCoreKit
import SignalClient

public struct SecretSessionKnownSenderError: Error {
    public let senderAddress: SMKAddress
    public let senderDeviceId: UInt32
    public let cipherType: CiphertextMessage.MessageType
    public let groupId: Data?
    public let unsealedContent: Data
    public let contentHint: UnidentifiedSenderMessageContent.ContentHint
    public let underlyingError: Error

    init(messageContent: UnidentifiedSenderMessageContent, underlyingError: Error) {
        self.senderAddress = SMKAddress(messageContent.senderCertificate.sender)
        self.senderDeviceId = messageContent.senderCertificate.sender.deviceId
        self.cipherType = messageContent.messageType
        self.groupId = messageContent.groupId.map { Data($0) }
        self.unsealedContent = Data(messageContent.contents)
        self.contentHint = messageContent.contentHint
        self.underlyingError = underlyingError
    }
}

@objc
public enum SMKSecretSessionCipherError: Int, Error {
    case selfSentMessage
}

// MARK: -

private class SMKSecretKeySpec: NSObject {

    @objc public let keyData: Data
    @objc public let algorithm: String

    init(keyData: Data, algorithm: String) {
        self.keyData = keyData
        self.algorithm = algorithm
    }
}

// MARK: -

private class SMKEphemeralKeys: NSObject {

    @objc public let chainKey: Data
    @objc public let cipherKey: SMKSecretKeySpec
    @objc public let macKey: SMKSecretKeySpec

    init(chainKey: Data, cipherKey: Data, macKey: Data) {
        self.chainKey = chainKey
        self.cipherKey = SMKSecretKeySpec(keyData: cipherKey, algorithm: "AES")
        self.macKey = SMKSecretKeySpec(keyData: macKey, algorithm: "HmacSHA256")
    }
}

// MARK: -

private class SMKStaticKeys: NSObject {

    @objc public let cipherKey: SMKSecretKeySpec
    @objc public let macKey: SMKSecretKeySpec

    init(cipherKey: Data, macKey: Data) {
        self.cipherKey = SMKSecretKeySpec(keyData: cipherKey, algorithm: "AES")
        self.macKey = SMKSecretKeySpec(keyData: macKey, algorithm: "HmacSHA256")
    }
}

// MARK: -

@objc public enum SMKMessageType: Int {
    case whisper
    case prekey
    case senderKey
    case plaintext
}

@objc
public class SMKDecryptResult: NSObject {

    public let senderAddress: SMKAddress

    @objc public var senderE164: String? {
        return senderAddress.e164
    }

    @objc public var senderUuid: UUID? {
        return senderAddress.uuid
    }

    @objc public let senderDeviceId: Int
    @objc public let paddedPayload: Data
    @objc public let messageType: SMKMessageType

    init(senderAddress: SMKAddress,
         senderDeviceId: Int,
         paddedPayload: Data,
         messageType: SMKMessageType) {
        self.senderAddress = senderAddress
        self.senderDeviceId = senderDeviceId
        self.paddedPayload = paddedPayload
        self.messageType = messageType
    }
}

// MARK: -

fileprivate extension ProtocolAddress {
    convenience init(from recipientAddress: SMKAddress, deviceId: UInt32) throws {
        try self.init(name: recipientAddress.uuid?.uuidString ?? recipientAddress.e164!, deviceId: deviceId)
    }

    convenience init(from senderAddress: SealedSenderAddress) throws {
        try self.init(name: senderAddress.uuidString, deviceId: senderAddress.deviceId)
    }
}

fileprivate extension SMKAddress {
    init(_ address: SealedSenderAddress) {
        try! self.init(uuid: UUID(uuidString: address.uuidString), e164: address.e164)
    }
}

fileprivate extension SMKMessageType {
    init(_ messageType: CiphertextMessage.MessageType) {
        switch messageType {
        case .whisper:
            self = .whisper
        case .preKey:
            self = .prekey
        case .senderKey:
            self = .senderKey
        case .plaintext:
            self = .plaintext
        default:
            fatalError("not ready for other kinds of messages yet")
        }
    }
}

@objc public class SMKSecretSessionCipher: NSObject {

    private let kUDPrefixString = "UnidentifiedDelivery"

    private let kSMKSecretSessionCipherMacLength: UInt = 10

    private let sessionStore: SessionStore
    private let preKeyStore: PreKeyStore
    private let signedPreKeyStore: SignedPreKeyStore
    private let identityStore: IdentityKeyStore
    private let senderKeyStore: SenderKeyStore

    // public SecretSessionCipher(SignalProtocolStore signalProtocolStore) {
    public init(sessionStore: SessionStore,
                preKeyStore: PreKeyStore,
                signedPreKeyStore: SignedPreKeyStore,
                identityStore: IdentityKeyStore,
                senderKeyStore: SenderKeyStore) throws {

        self.sessionStore = sessionStore
        self.preKeyStore = preKeyStore
        self.signedPreKeyStore = signedPreKeyStore
        self.identityStore = identityStore
        self.senderKeyStore = senderKeyStore
    }

    // MARK: - Public

    public func encryptMessage(
        recipient: SMKAddress,
        deviceId: Int32,
        paddedPlaintext: Data,
        contentHint: UnidentifiedSenderMessageContent.ContentHint,
        groupId: Data?,
        senderCertificate: SenderCertificate,
        protocolContext: StoreContext
    ) throws -> Data {

        guard deviceId > 0 else {
            throw SMKError.assertionError(description: "\(logTag) invalid deviceId")
        }
        let recipientAddress = try ProtocolAddress(from: recipient, deviceId: UInt32(bitPattern: deviceId))


        let ciphertextMessage = try signalEncrypt(
            message: paddedPlaintext,
            for: recipientAddress,
            sessionStore: sessionStore,
            identityStore: identityStore,
            context: protocolContext)

        let usmc = try UnidentifiedSenderMessageContent(
            ciphertextMessage,
            from: senderCertificate,
            contentHint: contentHint,
            groupId: groupId ?? Data())

        let outerBytes = try sealedSenderEncrypt(
            usmc,
            for: recipientAddress,
            identityStore: identityStore,
            context: protocolContext)

        return Data(outerBytes)
    }

    public func groupEncryptMessage(recipients: [ProtocolAddress],
                                    paddedPlaintext: Data,
                                    senderCertificate: SenderCertificate,
                                    groupId: Data,
                                    distributionId: UUID,
                                    contentHint: UnidentifiedSenderMessageContent.ContentHint = .default,
                                    protocolContext: StoreContext?) throws -> Data {

        let senderAddress = try ProtocolAddress(from: senderCertificate.sender)
        let ciphertext = try groupEncrypt(
            paddedPlaintext,
            from: senderAddress,
            distributionId: distributionId,
            store: senderKeyStore,
            context: protocolContext ?? NullContext())

        let udMessageContent = try UnidentifiedSenderMessageContent(
            ciphertext,
            from: senderCertificate,
            contentHint: contentHint,
            groupId: groupId)

        let multiRecipientMessage = try sealedSenderMultiRecipientEncrypt(
            udMessageContent,
            for: recipients,
            identityStore: identityStore,
            sessionStore: sessionStore,
            context: protocolContext ?? NullContext())

        return Data(multiRecipientMessage)
    }

    // public Pair<SignalProtocolAddress, byte[]> decrypt(CertificateValidator validator, byte[] ciphertext, long timestamp)
    //    throws InvalidMetadataMessageException, InvalidMetadataVersionException, ProtocolInvalidMessageException, ProtocolInvalidKeyException, ProtocolNoSessionException, ProtocolLegacyMessageException, ProtocolInvalidVersionException, ProtocolDuplicateMessageException, ProtocolInvalidKeyIdException, ProtocolUntrustedIdentityException
    public func throwswrapped_decryptMessage(certificateValidator: SMKCertificateValidator,
                                             cipherTextData: Data,
                                             timestamp: UInt64,
                                             localE164: String?,
                                             localUuid: UUID?,
                                             localDeviceId: Int32,
                                             protocolContext: StoreContext?) throws -> SMKDecryptResult {
        guard timestamp > 0 else {
            throw SMKError.assertionError(description: "\(logTag) invalid timestamp")
        }

        // Allow nil contexts for testing.
        let context = protocolContext ?? NullContext()
        let messageContent = try UnidentifiedSenderMessageContent(message: cipherTextData,
                                                                  identityStore: self.identityStore,
                                                                  context: context)

        let senderAddress = messageContent.senderCertificate.sender
        let localAddress = try SMKAddress(uuid: localUuid, e164: localE164)

        guard !SMKAddress(senderAddress).matches(localAddress) ||
                Int32(bitPattern: senderAddress.deviceId) != localDeviceId else {
            Logger.info("Discarding self-sent message")
            throw SMKSecretSessionCipherError.selfSentMessage
        }

        do {
            // validator.validate(content.getSenderCertificate(), timestamp);
            try certificateValidator.throwswrapped_validate(
                senderCertificate: messageContent.senderCertificate,
                validationTime: timestamp)

            let paddedMessagePlaintext = try throwswrapped_decrypt(messageContent: messageContent,
                                                                   context: context)

            // return new Pair<>(new SignalProtocolAddress(content.getSenderCertificate().getSender(),
            //     content.getSenderCertificate().getSenderDeviceId()),
            //     decrypt(content));
            //
            // NOTE: We use the sender properties from the sender certificate, not from this class' properties.
            guard senderAddress.deviceId <= Int32.max else {
                throw SMKError.assertionError(description: "\(logTag) Invalid senderDeviceId.")
            }
            return SMKDecryptResult(senderAddress: SMKAddress(senderAddress),
                                    senderDeviceId: Int(senderAddress.deviceId),
                                    paddedPayload: Data(paddedMessagePlaintext),
                                    messageType: SMKMessageType(messageContent.messageType))
        } catch {
            throw SecretSessionKnownSenderError(messageContent: messageContent,
                                                underlyingError: error)
        }
    }

    // MARK: - Decrypt

    // private byte[] decrypt(UnidentifiedSenderMessageContent message)
    // throws InvalidVersionException, InvalidMessageException, InvalidKeyException, DuplicateMessageException,
    // InvalidKeyIdException, UntrustedIdentityException, LegacyMessageException, NoSessionException
    private func throwswrapped_decrypt(messageContent: UnidentifiedSenderMessageContent,
                                       context: StoreContext) throws -> Data {

        // SignalProtocolAddress sender = new SignalProtocolAddress(message.getSenderCertificate().getSender(),
        // message.getSenderCertificate().getSenderDeviceId());
        //
        // NOTE: We use the sender properties from the sender certificate, not from this class' properties.
        let sender = messageContent.senderCertificate.sender
        guard sender.deviceId >= 0 && sender.deviceId <= Int32.max else {
            throw SMKError.assertionError(description: "\(logTag) Invalid senderDeviceId.")
        }

        // switch (message.getType()) {
        // case CiphertextMessage.WHISPER_TYPE: return new SessionCipher(signalProtocolStore, sender).decrypt(new
        // SignalMessage(message.getContent())); case CiphertextMessage.PREKEY_TYPE: return new
        // SessionCipher(signalProtocolStore, sender).decrypt(new PreKeySignalMessage(message.getContent())); default: throw
        // new InvalidMessageException("Unknown type: " + message.getType());
        // }
        let plaintextData: [UInt8]
        switch messageContent.messageType {
        case .whisper:
            let cipherMessage = try SignalMessage(bytes: messageContent.contents)
            plaintextData = try signalDecrypt(
                message: cipherMessage,
                from: ProtocolAddress(from: sender),
                sessionStore: sessionStore,
                identityStore: identityStore,
                context: context)
        case .preKey:
            let cipherMessage = try PreKeySignalMessage(bytes: messageContent.contents)
            plaintextData = try signalDecryptPreKey(
                message: cipherMessage,
                from: ProtocolAddress(from: sender),
                sessionStore: sessionStore,
                identityStore: identityStore,
                preKeyStore: preKeyStore,
                signedPreKeyStore: signedPreKeyStore,
                context: context)
        case .senderKey:
            plaintextData = try groupDecrypt(
                messageContent.contents,
                from: ProtocolAddress(from: sender),
                store: senderKeyStore,
                context: context)
        case .plaintext:
            let plaintextMessage = try PlaintextContent(bytes: messageContent.contents)
            plaintextData = plaintextMessage.body
        case let unknownType:
            throw SMKError.assertionError(
                description: "\(logTag) Not prepared to handle this message type: \(unknownType.rawValue)")
        }
        return Data(plaintextData)
    }
}

// MARK: - Internal for testing

extension SMKSecretSessionCipher {

    // Only allow nil contexts for testing
    func encryptMessage(
        recipient: SMKAddress,
        deviceId: Int32,
        paddedPlaintext: Data,
        contentHint: UnidentifiedSenderMessageContent.ContentHint = .default,
        groupId: Data? = nil,
        senderCertificate: SenderCertificate,
        protocolContext: StoreContext? = nil
    ) throws -> Data {
        try encryptMessage(
            recipient: recipient,
            deviceId: deviceId,
            paddedPlaintext: paddedPlaintext,
            contentHint: contentHint,
            groupId: groupId,
            senderCertificate: senderCertificate,
            protocolContext: protocolContext ?? NullContext())
    }
}
