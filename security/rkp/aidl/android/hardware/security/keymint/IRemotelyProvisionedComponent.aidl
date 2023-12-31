/*
 * Copyright (C) 2020 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package android.hardware.security.keymint;

import android.hardware.security.keymint.DeviceInfo;
import android.hardware.security.keymint.MacedPublicKey;
import android.hardware.security.keymint.ProtectedData;
import android.hardware.security.keymint.RpcHardwareInfo;

/**
 * An IRemotelyProvisionedComponent is a secure-side component for which certificates can be
 * remotely provisioned. It provides an interface for generating asymmetric key pairs and then
 * creating a CertificateRequest that contains the generated public keys, plus other information to
 * authenticate the request origin. The CertificateRequest can be sent to a server, which can
 * validate the request and create certificates.
 *
 * This interface does not provide any way to use the generated and certified key pairs. It's
 * intended to be implemented by a HAL service that does other things with keys (e.g. KeyMint).
 *
 * The root of trust for secure provisioning is something called the Device Identifier Composition
 * Engine (DICE) Chain. The DICE Chain is a chain of certificates, represented as COSE_Sign1 objects
 * containing CBOR Web Tokens (CWT) which have descriptions about the stage of firmware being
 * signed, including a COSE_Key representation of that stage's public key.
 *
 * DICE Chain Design
 * =================
 *
 * For a more exhaustive and thorough look at DICE and the implementation used within this protocol,
 * please see: https://pigweed.googlesource.com/open-dice/+/HEAD/docs/specification.md
 *
 * The DICE Chain is designed to mirror the boot stages of a device, and to prove the content and
 * integrity of each firmware image. In a proper DICE Chain, each boot stage hashes its own private
 * key material with the code and any relevant configuration parameters of the next stage to produce
 * a Compound Device Identifier, or CDI, which is used as the secret key material for the next
 * stage. From the CDI, a key pair - CDI_*_Pub and CDI_*_Priv - is derived and certified for the
 * next stage by the current stages CDI_*_Priv. The next stage is then loaded and given its CDI and
 * the DICE certificate chain generated so far in a manner that does not leak the previous stage's
 * CDI_*_Priv or CDI to later boot stages. The final, "leaf" CDI certificate contains a public key,
 * denoted CDI_Leaf_Pub, whose corresponding private key, denoted CDI_Leaf_Priv, is available for
 * use by the IRemotelyProvisionedComponent.
 *
 * The root keypair is generated by immutable code (e.g. ROM), from a Unique Device Secret (UDS).
 * The keypair that is generated from it can be referred to as the UDS_Pub/UDS_Priv keys. After the
 * device-unique secret is used, it must be made unavailable to any later boot stage.
 *
 * In this way, booting the device incrementally builds a certificate chain that (a) identifies and
 * validates the integrity of every stage and (b) contains a set of public keys that correspond to
 * private keys, one known to each stage. Any stage can compute the secrets of all later stages
 * (given the necessary input), but no stage can compute the secret of any preceding stage. Updating
 * the firmware or configuration of any stage changes the key pair of that stage, and of all
 * subsequent stages, and no attacker who compromised the previous version of the updated firmware
 * can know or predict the post-update key pairs. It is recommended and expected that the DICE Chain
 * is constructed using the Open Profile for DICE.
 *
 * When the provisioning server receives a message signed by CDI_Leaf_Priv and containing a DICE
 * chain that chains from UDS_Pub to CDI_Leaf_Pub, it can be certain that (barring vulnerabilities
 * in some boot stage), the CertificateRequest came from the device associated with UDS_Pub, running
 * the specific software identified by the certificates in the chain. If the server has some
 * mechanism for knowing the hash values of compromised stages, it can determine whether signing
 * certificates is appropriate.
 *
 * Degenerate DICE Chains
 * ======================
 *
 * While a proper DICE Chain, as described above, reflects the complete boot sequence from boot ROM
 * to the secure area image of the IRemotelyProvisionedComponent, it's also possible to use a
 * "degenerate" DICE Chain which consists only of a single, self-signed certificate containing the
 * public key of a hardware-bound key pair. This is an appropriate solution for devices which
 * haven't implemented everything necessary to produce a proper DICE Chain, but can derive a unique
 * key pair in the secure area. In this degenerate case, UDS_Pub is the same as CDI_Leaf_Pub.
 *
 * DICE Chain Privacy
 * ==================
 *
 * Because the DICE Chain constitutes an unspoofable, device-unique identifier, special care is
 * taken to prevent its availability to entities who may wish to track devices. Three precautions
 * are taken:
 *
 * 1) The DICE chain is only handled by the native Remote Key Provisioning Daemon (RKPD) service on
 *    the HLOS and is not exposed to apps running on device.
 *
 * 2) The CDI_Leaf_Priv key cannot be used to sign arbitrary data.
 *
 * 3) Backend infrastructure does not correlate UDS_Pub with the certificates signed and sent back
 *    to the device.
 *
 * Versioning
 * ==========
 * Versions 1 and 2 of the schema, as previously defined in DeviceInfo.aidl, diverge in
 * functionality from Version 3. Version 3 removes the need to have testMode in function calls and
 * deprecates the Endpoint Encryption Key (EEK) as well. Vendors implementing Version 1
 * (Android S/12) or Version 2 (Android T/13) do not need to implement generateCertificateRequestV2.
 * Vendors implementing Version 3 (Android U/14) need to implement generateCertificateRequestV2.
 *
 * For better coverage of changes from version to version, please see RKP_CHANGELOG.md in the root
 * of the keymint interface directory.
 *
 * @hide
 */
@VintfStability
interface IRemotelyProvisionedComponent {
    const int STATUS_FAILED = 1;
    const int STATUS_INVALID_MAC = 2;
    const int STATUS_PRODUCTION_KEY_IN_TEST_REQUEST = 3; // Versions 1 and 2 Only
    const int STATUS_TEST_KEY_IN_PRODUCTION_REQUEST = 4;
    const int STATUS_INVALID_EEK = 5; // Versions 1 and 2 Only
    const int STATUS_REMOVED = 6;

    /**
     * @return info which contains information about the underlying IRemotelyProvisionedComponent
     *         hardware, such as version number, component name, author name, and supported curve.
     */
    RpcHardwareInfo getHardwareInfo();

    /**
     * generateKeyPair generates a new ECDSA P-256 key pair that can be attested by the remote
     * server.
     *
     * @param in boolean testMode indicates whether the generated key is for testing only. Test keys
     *        are marked (see the definition of PublicKey in the MacedPublicKey structure) to
     *        prevent them from being confused with production keys.
     *
     *        This parameter has been deprecated since version 3 of the HAL and will always be
     *        false. From v3, if this parameter is true, the method must raise a
     *        ServiceSpecificException with an error of code of STATUS_REMOVED.
     *
     * @param out MacedPublicKey macedPublicKey contains the public key of the generated key pair,
     *        MACed so that generateCertificateRequest can easily verify, without the
     *        privateKeyHandle, that the contained public key is for remote certification.
     *
     * @return data representing a handle to the private key. The format is implementation-defined,
     *         but note that specific services may define a required format. KeyMint does.
     */
    byte[] generateEcdsaP256KeyPair(in boolean testMode, out MacedPublicKey macedPublicKey);

    /**
     * This method has been deprecated since version 3 of the HAL. The header is kept around for
     * backwards compatibility purposes. From v3, this method must raise a ServiceSpecificException
     * with an error code of STATUS_REMOVED.
     *
     * For v1 and v2 implementations:
     * generateCertificateRequest creates a certificate request to be sent to the provisioning
     * server.
     *
     * @param in boolean testMode indicates whether the generated certificate request is for testing
     *        only.
     *
     * @param in MacedPublicKey[] keysToSign contains the set of keys to certify. The
     *        IRemotelyProvisionedComponent must validate the MACs on each key.  If any entry in the
     *        array lacks a valid MAC, the method must return STATUS_INVALID_MAC.
     *
     *        If testMode is true, the keysToSign array must contain only keys flagged as test
     *        keys. Otherwise, the method must return STATUS_PRODUCTION_KEY_IN_TEST_REQUEST.
     *
     *        If testMode is false, the keysToSign array must not contain any keys flagged as
     *        test keys. Otherwise, the method must return STATUS_TEST_KEY_IN_PRODUCTION_REQUEST.
     *
     * @param in endpointEncryptionKey contains an X25519 or P-256 public key which will be used to
     *        encrypt the BCC. For flexibility, this is represented as a certificate chain
     *        in the form of a CBOR array of COSE_Sign1 objects, ordered from root to leaf.  An
     *        implementor may also choose to use P256 as an alternative curve for signing and
     *        encryption instead of Curve 25519, as indicated by the supportedEekCurve field in
     *        RpcHardwareInfo; the contents of the EEK chain will match the specified
     *        supportedEekCurve.
     *
     *        - For CURVE_25519 the leaf contains the X25519 agreement key, each other element is an
     *          Ed25519 key signing the next in the chain.
     *
     *        - For CURVE_P256 the leaf contains the P-256 agreement key, each other element is a
     *          P-256 key signing the next in the chain.
     *
     *        In either case, the root is self-signed.
     *
     *            EekChain = [ + SignedSignatureKey, SignedEek ]
     *
     *            SignedSignatureKey = [              ; COSE_Sign1
     *                protected: bstr .cbor {
     *                    1 : AlgorithmEdDSA / AlgorithmES256,  ; Algorithm
     *                },
     *                unprotected: {},
     *                payload: bstr .cbor SignatureKeyEd25519 /
     *                         bstr .cbor SignatureKeyP256,
     *                signature: bstr PureEd25519(.cbor SignatureKeySignatureInput) /
     *                           bstr ECDSA(.cbor SignatureKeySignatureInput)
     *            ]
     *
     *            SignatureKeyEd25519 = {             ; COSE_Key
     *                 1 : 1,                         ; Key type : Octet Key Pair
     *                 3 : AlgorithmEdDSA,            ; Algorithm
     *                 -1 : 6,                        ; Curve : Ed25519
     *                 -2 : bstr                      ; Ed25519 public key
     *            }
     *
     *            SignatureKeyP256 = {                ; COSE_Key
     *                 1 : 2,                         ; Key type : EC2
     *                 3 : AlgorithmES256,            ; Algorithm
     *                 -1 : 1,                        ; Curve: P256
     *                 -2 : bstr,                     ; X coordinate
     *                 -3 : bstr                      ; Y coordinate
     *            }
     *
     *            SignatureKeySignatureInput = [
     *                context: "Signature1",
     *                body_protected: bstr .cbor { 1 : AlgorithmEdDSA / AlgorithmES256 },
     *                external_aad: bstr .size 0,
     *                payload: bstr .cbor SignatureKeyEd25519 /
     *                         bstr .cbor SignatureKeyP256
     *            ]
     *
     *            ; COSE_Sign1
     *            SignedEek = [
     *                protected: bstr .cbor { 1 : AlgorithmEdDSA / AlgorithmES256 },
     *                unprotected: {},
     *                payload: bstr .cbor EekX25519 / .cbor EekP256,
     *                signature: bstr PureEd25519(.cbor EekSignatureInput) /
     *                           bstr ECDSA(.cbor EekSignatureInput)
     *            ]
     *
     *            EekX25519 = {            ; COSE_Key
     *                1 : 1,               ; Key type : Octet Key Pair
     *                2 : bstr             ; KID : EEK ID
     *                3 : -25,             ; Algorithm : ECDH-ES + HKDF-256
     *                -1 : 4,              ; Curve : X25519
     *                -2 : bstr            ; X25519 public key, little-endian
     *            }
     *
     *            EekP256 = {              ; COSE_Key
     *                1 : 2,               ; Key type : EC2
     *                2 : bstr             ; KID : EEK ID
     *                3 : -25,             ; Algorithm : ECDH-ES + HKDF-256
     *                -1 : 1,              ; Curve : P256
     *                -2 : bstr            ; Sender X coordinate
     *                -3 : bstr            ; Sender Y coordinate
     *            }
     *
     *            EekSignatureInput = [
     *                context: "Signature1",
     *                body_protected: bstr .cbor { 1 : AlgorithmEdDSA / AlgorithmES256 },
     *                external_aad: bstr .size 0,
     *                payload: bstr .cbor EekX25519 / .cbor EekP256
     *            ]
     *
     *            AlgorithmES256 = -7      ; RFC 8152 section 8.1
     *            AlgorithmEdDSA = -8      ; RFC 8152 section 8.2
     *
     *        If the contents of endpointEncryptionKey do not match the SignedEek structure above,
     *        the method must return STATUS_INVALID_EEK.
     *
     *        If testMode is true, the method must ignore the length and content of the signatures
     *        in the chain, which implies that it must not attempt to validate the signature.
     *
     *        If testMode is false, the method must validate the chain signatures, and must verify
     *        that the public key in the root certificate is in its pre-configured set of
     *        authorized EEK root keys. If the public key is not in the database, or if signature
     *        verification fails, the method must return STATUS_INVALID_EEK.
     *
     * @param in challenge contains a byte string from the provisioning server that must be signed
     *        by the secure area. See the description of the 'signature' output parameter for
     *        details.
     *
     * @param out DeviceInfo contains the VerifiedDeviceInfo portion of the DeviceInfo array in
     *        CertificateRequest. The structure is described within the DeviceInfo.aidl file.
     *
     * @param out ProtectedData contains the encrypted BCC and the ephemeral MAC key used to
     *        authenticate the keysToSign (see keysToSignMac output argument).
     *
     * @return The MAC of KeysToSign in the CertificateRequest structure. Specifically, it contains:
     *
     *            HMAC-256(EK_mac, .cbor KeysToMacStructure)
     *
     *        Where EK_mac is an ephemeral MAC key, found in ProtectedData (see below).  The MACed
     *        data is the "tag" field of a COSE_Mac0 structure like:
     *
     *            MacedKeys = [                            ; COSE_Mac0
     *                protected : bstr .cbor {
     *                    1 : 5,                           ; Algorithm : HMAC-256
     *                },
     *                unprotected : {},
     *                ; Payload is PublicKeys from keysToSign argument, in provided order.
     *                payload: bstr .cbor [ * PublicKey ],
     *                tag: bstr
     *            ]
     *
     *            KeysToMacStructure = [
     *                context : "MAC0",
     *                protected : bstr .cbor { 1 : 5 },    ; Algorithm : HMAC-256
     *                external_aad : bstr .size 0,
     *                ; Payload is PublicKeys from keysToSign argument, in provided order.
     *                payload : bstr .cbor [ * PublicKey ]
     *            ]
     */
    byte[] generateCertificateRequest(in boolean testMode, in MacedPublicKey[] keysToSign,
            in byte[] endpointEncryptionCertChain, in byte[] challenge, out DeviceInfo deviceInfo,
            out ProtectedData protectedData);

    /**
     * generateCertificateRequestV2 creates a certificate signing request to be sent to the
     * provisioning server.
     *
     * @param in MacedPublicKey[] keysToSign contains the set of keys to certify. The
     *        IRemotelyProvisionedComponent must validate the MACs on each key.  If any entry in the
     *        array lacks a valid MAC, the method must return STATUS_INVALID_MAC.  This method must
     *        not accept test keys. If any entry in the array is a test key, the method must return
     *        STATUS_TEST_KEY_IN_PRODUCTION_REQUEST.
     *
     * @param in challenge contains a byte string from the provisioning server which will be
     *        included in the signed data of the CSR structure. Different provisioned backends may
     *        use different semantic data for this field, but the supported sizes must be between 0
     *        and 64 bytes, inclusive.
     *
     * @return the following CBOR Certificate Signing Request (Csr) serialized into a byte array:
     *
     * Csr = AuthenticatedRequest<CsrPayload>
     *
     * CsrPayload = [                      ; CBOR Array defining the payload for Csr
     *     version: 3,                     ; The CsrPayload CDDL Schema version.
     *     CertificateType,                ; The type of certificate being requested.
     *     DeviceInfo,                     ; Defined in DeviceInfo.aidl
     *     KeysToSign,                     ; Provided by the method parameters
     * ]
     *
     *  ; A tstr identifying the type of certificate. The set of supported certificate types may
     *  ; be extended without requiring a version bump of the HAL. Custom certificate types may
     *  ; be used, but the provisioning server may reject the request for an unknown certificate
     *  ; type. The currently defined certificate types are:
     *  ;  - "widevine"
     *  ;  - "keymint"
     *  CertificateType = tstr
     *
     * KeysToSign = [ * PublicKey ]   ; Please see MacedPublicKey.aidl for the PublicKey definition.
     *
     * AuthenticatedRequest<T> = [
     *     version: 1,              ; The AuthenticatedRequest CDDL Schema version.
     *     UdsCerts,
     *     DiceCertChain,
     *     SignedData<[
     *         challenge: bstr .size (0..64), ; Provided by the method parameters
     *         bstr .cbor T,
     *     ]>,
     * ]
     *
     * ; COSE_Sign1 (untagged)
     * SignedData<Data> = [
     *     protected: bstr .cbor { 1 : AlgorithmEdDSA / AlgorithmES256 / AlgorithmES384 },
     *     unprotected: {},
     *     payload: bstr .cbor Data / nil,
     *     signature: bstr      ; PureEd25519(CDI_Leaf_Priv, SignedDataSigStruct<Data>) /
     *                          ; ECDSA(CDI_Leaf_Priv, SignedDataSigStruct<Data>)
     * ]
     *
     * ; Sig_structure for SignedData
     * SignedDataSigStruct<Data> = [
     *     context: "Signature1",
     *     protected: bstr .cbor { 1 : AlgorithmEdDSA / AlgorithmES256 / AlgorithmES384 },
     *     external_aad: bstr .size 0,
     *     payload: bstr .cbor Data / nil,
     * ]
     *
     * ; UdsCerts allows the platform to provide additional certifications for the UDS_Pub. For
     * ; example, this could be provided by the hardware vendor, who certifies all of their chips.
     * ; The SignerName is a free-form string describing who generated the signature. The root
     * ; certificate will need to be communicated to the verifier out of band, along with the
     * ; SignerName that is expected for the given root certificate.
     * UdsCerts = {
     *     * SignerName => UdsCertChain
     * }
     *
     * ; SignerName is a string identifier that indicates both the signing authority as
     * ; well as the format of the UdsCertChain
     * SignerName = tstr
     *
     * UdsCertChain = [
     *     2* X509Certificate       ; Root -> ... -> Leaf. "Root" is the vendor self-signed
     *                              ; cert, "Leaf" contains UDS_Public. There may also be
     *                              ; intermediate certificates between Root and Leaf.
     * ]
     *
     * ; A bstr containing a DER-encoded X.509 certificate (RSA, NIST P-curve, or EdDSA)
     * X509Certificate = bstr
     *
     * ; The DICE Chain contains measurements about the device firmware.
     * ; The first entry in the DICE Chain is the UDS_Pub, encoded as a COSE_key. All entries
     * ; after the first describe a link in the boot chain (e.g. bootloaders: BL1, BL2, ... BLN)
     * ; Note that there is no DiceChainEntry for UDS_pub, only a "bare" COSE_key.
     * DiceCertChain = [
     *     PubKeyEd25519 / PubKeyECDSA256 / PubKeyECDSA384,  ; UDS_Pub
     *     + DiceChainEntry,                ; First CDI_Certificate -> Last CDI_Certificate
     *                                      ; Last certificate corresponds to KeyMint's DICE key.
     * ]
     *
     * ; This is the signed payload for each entry in the DICE chain. Note that the "Configuration
     * ; Input Values" described by the Open Profile are not used here. Instead, the DICE chain
     * ; defines its own configuration values for the Configuration Descriptor field. See
     * ; the Open Profile for DICE for more details on the fields. SHA256, SHA384 and SHA512 are
     * ; acceptable hash algorithms. The digest bstr values in the payload are the digest values
     * ; without any padding. Note that this implies that the digest is a 32-byte bstr for SHA256
     * ; and a 48-byte bstr for SHA384. This is an intentional, minor deviation from Open Profile
     * ; for DICE, which specifies all digests are 64 bytes.
     * DiceChainEntryPayload = {                    ; CWT [RFC8392]
     *     1 : tstr,                                ; Issuer
     *     2 : tstr,                                ; Subject
     *     -4670552 : bstr .cbor PubKeyEd25519 /
     *                bstr .cbor PubKeyECDSA256,
     *                bstr .cbor PubKeyECDSA384,    ; Subject Public Key
     *     -4670553 : bstr                          ; Key Usage
     *
     *     ; NOTE: All of the following fields may be omitted for a "Degenerate DICE Chain", as
     *     ;       described above.
     *     -4670545 : bstr,                         ; Code Hash
     *     ? -4670546 : bstr,                       ; Code Descriptor
     *     ? -4670547 : bstr,                       ; Configuration Hash
     *     -4670548 : bstr .cbor {                  ; Configuration Descriptor
     *         ? -70002 : tstr,                         ; Component name
     *         ? -70003 : int / tstr,                   ; Component version
     *         ? -70004 : null,                         ; Resettable
     *     },
     *     -4670549 : bstr,                         ; Authority Hash
     *     ? -4670550 : bstr,                       ; Authority Descriptor
     *     -4670551 : bstr,                         ; Mode
     * }
     *
     * ; Each entry in the DICE chain is a DiceChainEntryPayload signed by the key from the previous
     * ; entry in the DICE chain array.
     * DiceChainEntry = [                            ; COSE_Sign1 (untagged)
     *     protected : bstr .cbor { 1 : AlgorithmEdDSA / AlgorithmES256 / AlgorithmES384 },
     *     unprotected: {},
     *     payload: bstr .cbor DiceChainEntryPayload,
     *     signature: bstr ; PureEd25519(SigningKey, DiceChainEntryInput) /
     *                     ; ECDSA(SigningKey, DiceChainEntryInput)
     *                     ; See RFC 8032 for details of how to encode the signature value
     *                     ; for Ed25519.
     * ]
     *
     * DiceChainEntryInput = [
     *     context: "Signature1",
     *     protected: bstr .cbor { 1 : AlgorithmEdDSA / AlgorithmES256 / AlgorithmES384 },
     *     external_aad: bstr .size 0,
     *     payload: bstr .cbor DiceChainEntryPayload
     * ]
     *
     * ; The following section defines some types that are reused throughout the above
     * ; data structures.
     * ; NOTE: Integer encoding is different for Ed25519 and P256 keys:
     * ;       - Ed25519 is LE: https://www.rfc-editor.org/rfc/rfc8032#section-3.1
     * ;       - P256 is BE: https://www.secg.org/sec1-v2.pdf#page=19 (section 2.3.7)
     * PubKeyEd25519 = {                ; COSE_Key
     *     1 : 1,                       ; Key type : octet key pair
     *     3 : AlgorithmEdDSA,          ; Algorithm : EdDSA
     *     -1 : 6,                      ; Curve : Ed25519
     *     -2 : bstr                    ; X coordinate, little-endian
     * }
     *
     * PubKeyECDSA256 = {               ; COSE_Key
     *     1 : 2,                       ; Key type : EC2
     *     3 : AlgorithmES256,          ; Algorithm : ECDSA w/ SHA-256
     *     -1 : 1,                      ; Curve: P256
     *     -2 : bstr,                   ; X coordinate, big-endian
     *     -3 : bstr                    ; Y coordinate, big-endian
     * }
     *
     * PubKeyECDSA384 = {               ; COSE_Key
     *     1 : 2,                       ; Key type : EC2
     *     3 : AlgorithmES384,          ; Algorithm : ECDSA w/ SHA-384
     *     -1 : 2,                      ; Curve: P384
     *     -2 : bstr,                   ; X coordinate
     *     -3 : bstr                    ; Y coordinate
     * }
     *
     * AlgorithmES256 = -7
     * AlgorithmES384 = -35
     * AlgorithmEdDSA = -8
     */
    byte[] generateCertificateRequestV2(in MacedPublicKey[] keysToSign, in byte[] challenge);
}
