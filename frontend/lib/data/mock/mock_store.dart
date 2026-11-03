import 'dart:async';

/// 内存中的可观察值：订阅时先发当前值，之后推送变化。
class MockStore<T> {
  MockStore(this._value);

  T _value;
  final _changes = StreamController<T>.broadcast();

  T get value => _value;

  set value(T v) {
    _value = v;
    _changes.add(v);
  }

  Stream<T> watch() async* {
    yield _value;
    yield* _changes.stream;
  }
}
