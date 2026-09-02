package com.chromaglow.app.app

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import kotlinx.coroutines.launch

/**
 * Activity-scoped holder for the [AppShellController] so the live home survives configuration
 * changes and is closed exactly once when the Activity is finally destroyed.
 */
class AppShellViewModel internal constructor(graph: LiveAppGraph) : ViewModel() {

    val controller: AppShellController = AppShellController(
        workflow = graph.pairingWorkflow,
        liveHomeFactory = { scope -> graph.newLiveHome(scope) },
        scope = viewModelScope,
    )

    init {
        viewModelScope.launch { controller.restoreAtLaunch() }
    }

    override fun onCleared() {
        controller.close()
    }

    companion object {
        fun factory(context: Context): ViewModelProvider.Factory = viewModelFactory {
            initializer { AppShellViewModel(LiveAppGraph.get(context.applicationContext)) }
        }
    }
}
