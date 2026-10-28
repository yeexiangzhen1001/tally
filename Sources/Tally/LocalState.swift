import SwiftUI

/// 只装了 Command Line Tools（没有 Xcode）时的 `@State` 替身。
/// 新 SDK 里 `State` 是宏，由 SwiftUIMacros 插件展开，而 CLT 不带这个插件，直接用 `@State` 编不过。
/// 这里借 `@StateObject` 存值：生命周期跟视图一致，改值触发刷新，`$x` 给出 Binding。
final class LocalStateBox<Value>: ObservableObject {
    var value: Value {
        willSet { objectWillChange.send() }
    }

    init(_ value: Value) { self.value = value }
}

@propertyWrapper
struct LocalState<Value>: DynamicProperty {
    @StateObject private var box: LocalStateBox<Value>

    init(wrappedValue: Value) {
        _box = StateObject(wrappedValue: LocalStateBox(wrappedValue))
    }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> {
        Binding(get: { box.value }, set: { box.value = $0 })
    }
}
