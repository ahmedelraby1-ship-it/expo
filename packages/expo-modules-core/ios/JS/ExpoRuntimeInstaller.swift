// Copyright 2025-present 650 Industries. All rights reserved.

import ExpoModulesJSI

@JavaScriptActor
internal class ExpoRuntimeInstaller: EXJavaScriptRuntimeManager {
  private let appContext: AppContext
  private let runtime: ExpoRuntime

  internal init(appContext: AppContext, runtime: ExpoRuntime) {
    self.appContext = appContext
    self.runtime = runtime
    let pointer = runtime.withUnsafePointee { $0 }
    super.init(runtime: pointer)
  }

  /**
   Installs `global.expo`.
   */
  @JavaScriptActor
  @discardableResult
  internal func installCoreObject() -> JavaScriptObject {
    let coreObject = runtime.createObject()
    runtime.global().defineProperty(EXGlobalCoreObjectPropertyName, value: coreObject, options: [.enumerable])
    return coreObject
  }

  /**
   Installs `expo.modules`, the host object that returns module objects.
   */
  @JavaScriptActor
  internal func installExpoModulesHostObject() throws {
    let coreObject = try runtime.getCoreObject()

    if coreObject.hasProperty("modules") {
      // Host object already installed
      return
    }
    let modulesHostObject = runtime.createHostObject(
      get: { moduleName in
        return self.appContext.getNativeModuleObject(moduleName) ?? .undefined()
      },
      set: { propertyName, value in
        // TODO: Throw JS error
        fatalError("RuntimeError: Cannot override the host object for expo module '\(propertyName)'.")
      },
      getPropertyNames: {
        return self.appContext.getModuleNames()
      },
      dealloc: {
        self.appContext.destroy()
      }
    )

    // Define the `global.expo.modules` object as a non-configurable, read-only and enumerable property.
    coreObject.defineProperty("modules", value: modulesHostObject, options: [.enumerable])
  }
}
