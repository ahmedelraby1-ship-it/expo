package expo.modules.ui.menu

import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBoxScope
import expo.modules.kotlin.views.ComposableScope

@OptIn(ExperimentalMaterial3Api::class)
object ExposedDropdownMenuBoxScopeKey

@OptIn(ExperimentalMaterial3Api::class)
val ComposableScope.exposedDropdownMenuBoxScope: ExposedDropdownMenuBoxScope?
  get() = extras[ExposedDropdownMenuBoxScopeKey] as? ExposedDropdownMenuBoxScope
