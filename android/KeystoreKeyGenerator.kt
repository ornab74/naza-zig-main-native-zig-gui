package com.naza.keystore

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyPairGenerator

/** Generates the installer identity only after the host has confirmed u. */
object KeystoreKeyGenerator {
    const val alias = "naza-installer-rsa"

    fun generateAfterUnlockConfirmation(confirmed: Boolean) {
        check(confirmed) { "device lock/unlock confirmation is required" }
        val generator = KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_RSA,
            "AndroidKeyStore"
        )
        val spec = KeyGenParameterSpec.Builder(
            alias,
            KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY
        )
            .setKeySize(2048)
            .setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA512)
            .setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PSS)
            .setUserAuthenticationRequired(true)
            .build()
        generator.initialize(spec)
        generator.generateKeyPair()
    }
}
