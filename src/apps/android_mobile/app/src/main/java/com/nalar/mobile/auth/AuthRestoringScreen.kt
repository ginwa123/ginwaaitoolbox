package com.nalar.mobile.auth

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.nalar.mobile.ui.NalarAccent
import com.nalar.mobile.ui.NalarBackground
import com.nalar.mobile.ui.NalarBorder
import com.nalar.mobile.ui.NalarDim
import com.nalar.mobile.ui.NalarError
import com.nalar.mobile.ui.NalarMuted
import com.nalar.mobile.ui.NalarText

@Composable
fun AuthRestoringScreen(
    modifier: Modifier = Modifier,
    errorMessage: String? = null,
    onRetry: (() -> Unit)? = null,
    onUseAnotherAccount: (() -> Unit)? = null,
) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(NalarBackground)
            .statusBarsPadding()
            .navigationBarsPadding(),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (errorMessage == null) {
                CircularProgressIndicator(
                    modifier = Modifier
                        .size(32.dp)
                        .testTag("auth_restoring"),
                    color = NalarAccent,
                    strokeWidth = 3.dp,
                )
            }

            Text(
                text = if (errorMessage == null) {
                    "Restoring your session…"
                } else {
                    "Session check failed"
                },
                style = MaterialTheme.typography.titleMedium,
                color = NalarText,
                textAlign = TextAlign.Center,
            )
            Text(
                text = errorMessage ?: "Checking your Nalar account",
                modifier = Modifier.testTag("auth_restore_message"),
                style = MaterialTheme.typography.bodyMedium,
                color = if (errorMessage == null) NalarMuted else NalarError,
                textAlign = TextAlign.Center,
            )

            if (errorMessage != null) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Button(
                        onClick = { onRetry?.invoke() },
                        enabled = onRetry != null,
                        modifier = Modifier.testTag("auth_retry"),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = NalarAccent,
                            contentColor = NalarBackground,
                            disabledContainerColor = NalarBorder,
                            disabledContentColor = NalarMuted,
                        ),
                    ) {
                        Text(text = "Try again")
                    }
                    OutlinedButton(
                        onClick = { onUseAnotherAccount?.invoke() },
                        modifier = Modifier.testTag("auth_use_another_account"),
                    ) {
                        Text(text = "Sign in")
                    }
                }
                Text(
                    text = "Your saved session is kept until the server confirms it.",
                    style = MaterialTheme.typography.labelMedium,
                    color = NalarDim,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}
