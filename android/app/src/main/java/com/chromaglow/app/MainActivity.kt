package com.chromaglow.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.chromaglow.app.app.ChromaGlowApp
import com.chromaglow.app.ui.theme.ChromaGlowTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            ChromaGlowTheme {
                ChromaGlowApp()
            }
        }
    }
}
