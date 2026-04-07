// Copyright 2018-present 650 Industries. All rights reserved.

#import <ExpoModulesCore/EXJSIConversions.h>

namespace expo {

static jsi::Object convertNSDictionaryToJSIObject(jsi::Runtime &runtime, NSDictionary *value)
{
  jsi::Object result = jsi::Object(runtime);
  for (NSString *k in value) {
    result.setProperty(runtime, [k UTF8String], convertObjCObjectToJSIValue(runtime, value[k]));
  }
  return result;
}

static jsi::Array convertNSArrayToJSIArray(jsi::Runtime &runtime, NSArray *value)
{
  jsi::Array result = jsi::Array(runtime, value.count);
  for (size_t i = 0; i < value.count; i++) {
    result.setValueAtIndex(runtime, i, convertObjCObjectToJSIValue(runtime, value[i]));
  }
  return result;
}

jsi::Value convertObjCObjectToJSIValue(jsi::Runtime &runtime, id value)
{
  if (!value || value == (id)kCFNull) {
    return jsi::Value::null();
  }
  if ([value isKindOfClass:[NSString class]]) {
    return jsi::String::createFromUtf8(runtime, [value UTF8String]);
  }
  if ([value isKindOfClass:[NSNumber class]]) {
    if ([value isKindOfClass:[@YES class]]) {
      return jsi::Value((bool)[value boolValue]);
    }
    return jsi::Value([value doubleValue]);
  }
  if ([value isKindOfClass:[NSDictionary class]]) {
    return convertNSDictionaryToJSIObject(runtime, (NSDictionary *)value);
  }
  if ([value isKindOfClass:[NSArray class]]) {
    return convertNSArrayToJSIArray(runtime, (NSArray *)value);
  }
  if ([value isKindOfClass:[NSURL class]]) {
    return jsi::String::createFromUtf8(runtime, [[(NSURL *)value absoluteString] UTF8String]);
  }
  return jsi::Value::undefined();
}

} // namespace expo
