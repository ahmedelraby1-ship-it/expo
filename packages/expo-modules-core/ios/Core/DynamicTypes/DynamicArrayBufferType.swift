// Copyright 2015-present 650 Industries. All rights reserved.

import ExpoModulesJSI

internal struct DynamicArrayBufferType: AnyDynamicType {
  let innerType: any AnyArrayBuffer.Type

  func wraps<InnerType>(_ type: InnerType.Type) -> Bool {
    return innerType == InnerType.self
  }

  func equals(_ type: AnyDynamicType) -> Bool {
    if let arrayBufferType = type as? Self {
      return arrayBufferType.innerType == innerType
    }
    return false
  }

  /**
   Converts JS array buffer to its native representation.
   */
  func cast(jsValue: JavaScriptValue, appContext: AppContext) throws -> Any {
    if jsValue.isTypedArray() {
      let typedArray = jsValue.getTypedArray()
      if innerType is NativeArrayBuffer.Type {
        let pointer = typedArray.getUnsafeMutableRawPointer()
        let count = typedArray.byteLength
        return NativeArrayBuffer.copy(of: pointer, count: count)
      }
      // TODO: Get the underlying ArrayBuffer from the TypedArray (respecting byteOffset)
      throw ArrayBufferArgumentTypeException(innerType)
    }

    guard jsValue.isObject() else {
      throw NotArrayBufferException(innerType)
    }

    let object = jsValue.getObject()

    guard object.isArrayBuffer() else {
      throw NotArrayBufferException(innerType)
    }

    let jsArrayBuffer = object.getArrayBuffer()

    return switch innerType {
    case is NativeArrayBuffer.Type:
      NativeArrayBuffer.copy(of: UnsafeRawPointer(jsArrayBuffer.data()), count: jsArrayBuffer.size)
    default:
      ArrayBuffer(jsArrayBuffer)
    }
  }

  func castToJS<ValueType>(_ value: ValueType, appContext: AppContext) throws -> JavaScriptValue {
    if let nativeArrayBuffer = value as? NativeArrayBuffer {
      return nativeArrayBuffer.asJavaScriptArrayBuffer(runtime: try appContext.runtime).asValue()
    }
    if let arrayBuffer = value as? ArrayBuffer {
      return arrayBuffer.backingBuffer.asValue()
    }
    throw Conversions.ConversionToJSFailedException((kind: .object, nativeType: ValueType.self))
  }

  var description: String {
    return String(describing: Data.self)
  }
}

internal final class NotArrayBufferException: GenericException<any AnyArrayBuffer.Type>, @unchecked Sendable {
  override var reason: String {
    "Given argument is not an instance of \(param)"
  }
}

internal final class ArrayBufferArgumentTypeException: GenericException<any AnyArrayBuffer.Type>, @unchecked Sendable {
  override var reason: String {
    "\(param) cannot be used as argument type. Use either ArrayBuffer or NativeArrayBuffer"
  }
}
