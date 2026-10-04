package com.pabrik.mobile.login

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LoginValidationTest {
    @Test
    fun trimsEmailBeforeValidation() {
        val result = validateLogin("  person@example.com  ", "secret")

        assertTrue(result.isValid)
    }

    @Test
    fun redactsPasswordFromCredentialsString() {
        val credentials = LoginCredentials("person@example.com", "secret")

        assertFalse(credentials.toString().contains("secret"))
    }

    @Test
    fun reportsMissingEmailAndPassword() {
        val result = validateLogin("", "")

        assertFalse(result.isValid)
        assertEquals("Enter your email address.", result.emailError)
        assertEquals("Enter your password.", result.passwordError)
    }

    @Test
    fun rejectsMalformedEmail() {
        val result = validateLogin("not-an-email", "secret")

        assertFalse(result.isValid)
        assertEquals("Enter a valid email address.", result.emailError)
        assertEquals(null, result.passwordError)
    }
}
