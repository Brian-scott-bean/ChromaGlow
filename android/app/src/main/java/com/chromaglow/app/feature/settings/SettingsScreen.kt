package com.chromaglow.app.feature.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp

/** Test tag for the demo/live mode status value [Text]. */
const val SETTINGS_DEMO_STATUS_TAG: String = "settings_demo_status"

/** Test tag for the app-version value [Text]. */
const val SETTINGS_VERSION_TAG: String = "settings_version"

/** Test tag for the "Exit Demo Mode" [Button]. */
const val SETTINGS_EXIT_DEMO_TAG: String = "settings_exit_demo"

/** Test tag for the "Back" [OutlinedButton]. */
const val SETTINGS_BACK_TAG: String = "settings_back"

/**
 * Stateless Settings screen. Renders the current demo-mode status, the app version (a plain
 * [String] supplied by the caller — never read from BuildConfig, which is disabled on main),
 * and hoists the "Exit Demo Mode" and back actions out via [onExitDemo] and [onBack].
 *
 * Per architecture rule D-008 this composable takes everything it renders through parameters
 * and performs no persistence or credential wiring. The "Exit Demo Mode" action is only shown
 * while [isDemoMode] is true, since exiting demo mode is meaningless outside of it.
 */
@Composable
fun SettingsScreen(
    isDemoMode: Boolean,
    appVersion: String,
    onExitDemo: () -> Unit = {},
    onBack: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = "Settings",
            style = MaterialTheme.typography.headlineLarge,
            color = MaterialTheme.colorScheme.onBackground,
        )

        Surface(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(16.dp),
            color = MaterialTheme.colorScheme.surface,
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = "Mode",
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = if (isDemoMode) "Demo Mode" else "Live Mode",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.testTag(SETTINGS_DEMO_STATUS_TAG),
                    )
                }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = "App version",
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = appVersion,
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.testTag(SETTINGS_VERSION_TAG),
                    )
                }
            }
        }

        if (isDemoMode) {
            Button(
                onClick = onExitDemo,
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(SETTINGS_EXIT_DEMO_TAG),
            ) {
                Text(text = "Exit Demo Mode")
            }
        }

        OutlinedButton(
            onClick = onBack,
            modifier = Modifier
                .fillMaxWidth()
                .testTag(SETTINGS_BACK_TAG),
        ) {
            Text(text = "Back")
        }
    }
}
