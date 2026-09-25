// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'rdp.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$RdpEvent {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RdpEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'RdpEvent()';
}


}

/// @nodoc
class $RdpEventCopyWith<$Res>  {
$RdpEventCopyWith(RdpEvent _, $Res Function(RdpEvent) __);
}


/// Adds pattern-matching-related methods to [RdpEvent].
extension RdpEventPatterns on RdpEvent {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( RdpEvent_Connected value)?  connected,TResult Function( RdpEvent_FrameUpdate value)?  frameUpdate,TResult Function( RdpEvent_Clipboard value)?  clipboard,TResult Function( RdpEvent_ClipboardTransfer value)?  clipboardTransfer,TResult Function( RdpEvent_Disconnected value)?  disconnected,TResult Function( RdpEvent_Error value)?  error,required TResult orElse(),}){
final _that = this;
switch (_that) {
case RdpEvent_Connected() when connected != null:
return connected(_that);case RdpEvent_FrameUpdate() when frameUpdate != null:
return frameUpdate(_that);case RdpEvent_Clipboard() when clipboard != null:
return clipboard(_that);case RdpEvent_ClipboardTransfer() when clipboardTransfer != null:
return clipboardTransfer(_that);case RdpEvent_Disconnected() when disconnected != null:
return disconnected(_that);case RdpEvent_Error() when error != null:
return error(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( RdpEvent_Connected value)  connected,required TResult Function( RdpEvent_FrameUpdate value)  frameUpdate,required TResult Function( RdpEvent_Clipboard value)  clipboard,required TResult Function( RdpEvent_ClipboardTransfer value)  clipboardTransfer,required TResult Function( RdpEvent_Disconnected value)  disconnected,required TResult Function( RdpEvent_Error value)  error,}){
final _that = this;
switch (_that) {
case RdpEvent_Connected():
return connected(_that);case RdpEvent_FrameUpdate():
return frameUpdate(_that);case RdpEvent_Clipboard():
return clipboard(_that);case RdpEvent_ClipboardTransfer():
return clipboardTransfer(_that);case RdpEvent_Disconnected():
return disconnected(_that);case RdpEvent_Error():
return error(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( RdpEvent_Connected value)?  connected,TResult? Function( RdpEvent_FrameUpdate value)?  frameUpdate,TResult? Function( RdpEvent_Clipboard value)?  clipboard,TResult? Function( RdpEvent_ClipboardTransfer value)?  clipboardTransfer,TResult? Function( RdpEvent_Disconnected value)?  disconnected,TResult? Function( RdpEvent_Error value)?  error,}){
final _that = this;
switch (_that) {
case RdpEvent_Connected() when connected != null:
return connected(_that);case RdpEvent_FrameUpdate() when frameUpdate != null:
return frameUpdate(_that);case RdpEvent_Clipboard() when clipboard != null:
return clipboard(_that);case RdpEvent_ClipboardTransfer() when clipboardTransfer != null:
return clipboardTransfer(_that);case RdpEvent_Disconnected() when disconnected != null:
return disconnected(_that);case RdpEvent_Error() when error != null:
return error(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( int width,  int height,  Uint8List certificate)?  connected,TResult Function( int x,  int y,  int width,  int height,  Uint8List pixels)?  frameUpdate,TResult Function( String text)?  clipboard,TResult Function( bool sending,  String fileName,  int index,  int fileCount,  BigInt transferred,  BigInt total,  bool complete)?  clipboardTransfer,TResult Function( String reason)?  disconnected,TResult Function( String message)?  error,required TResult orElse(),}) {final _that = this;
switch (_that) {
case RdpEvent_Connected() when connected != null:
return connected(_that.width,_that.height,_that.certificate);case RdpEvent_FrameUpdate() when frameUpdate != null:
return frameUpdate(_that.x,_that.y,_that.width,_that.height,_that.pixels);case RdpEvent_Clipboard() when clipboard != null:
return clipboard(_that.text);case RdpEvent_ClipboardTransfer() when clipboardTransfer != null:
return clipboardTransfer(_that.sending,_that.fileName,_that.index,_that.fileCount,_that.transferred,_that.total,_that.complete);case RdpEvent_Disconnected() when disconnected != null:
return disconnected(_that.reason);case RdpEvent_Error() when error != null:
return error(_that.message);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( int width,  int height,  Uint8List certificate)  connected,required TResult Function( int x,  int y,  int width,  int height,  Uint8List pixels)  frameUpdate,required TResult Function( String text)  clipboard,required TResult Function( bool sending,  String fileName,  int index,  int fileCount,  BigInt transferred,  BigInt total,  bool complete)  clipboardTransfer,required TResult Function( String reason)  disconnected,required TResult Function( String message)  error,}) {final _that = this;
switch (_that) {
case RdpEvent_Connected():
return connected(_that.width,_that.height,_that.certificate);case RdpEvent_FrameUpdate():
return frameUpdate(_that.x,_that.y,_that.width,_that.height,_that.pixels);case RdpEvent_Clipboard():
return clipboard(_that.text);case RdpEvent_ClipboardTransfer():
return clipboardTransfer(_that.sending,_that.fileName,_that.index,_that.fileCount,_that.transferred,_that.total,_that.complete);case RdpEvent_Disconnected():
return disconnected(_that.reason);case RdpEvent_Error():
return error(_that.message);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( int width,  int height,  Uint8List certificate)?  connected,TResult? Function( int x,  int y,  int width,  int height,  Uint8List pixels)?  frameUpdate,TResult? Function( String text)?  clipboard,TResult? Function( bool sending,  String fileName,  int index,  int fileCount,  BigInt transferred,  BigInt total,  bool complete)?  clipboardTransfer,TResult? Function( String reason)?  disconnected,TResult? Function( String message)?  error,}) {final _that = this;
switch (_that) {
case RdpEvent_Connected() when connected != null:
return connected(_that.width,_that.height,_that.certificate);case RdpEvent_FrameUpdate() when frameUpdate != null:
return frameUpdate(_that.x,_that.y,_that.width,_that.height,_that.pixels);case RdpEvent_Clipboard() when clipboard != null:
return clipboard(_that.text);case RdpEvent_ClipboardTransfer() when clipboardTransfer != null:
return clipboardTransfer(_that.sending,_that.fileName,_that.index,_that.fileCount,_that.transferred,_that.total,_that.complete);case RdpEvent_Disconnected() when disconnected != null:
return disconnected(_that.reason);case RdpEvent_Error() when error != null:
return error(_that.message);case _:
  return null;

}
}

}

/// @nodoc


class RdpEvent_Connected extends RdpEvent {
  const RdpEvent_Connected({required this.width, required this.height, required this.certificate}): super._();
  

 final  int width;
 final  int height;
 final  Uint8List certificate;

/// Create a copy of RdpEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RdpEvent_ConnectedCopyWith<RdpEvent_Connected> get copyWith => _$RdpEvent_ConnectedCopyWithImpl<RdpEvent_Connected>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RdpEvent_Connected&&(identical(other.width, width) || other.width == width)&&(identical(other.height, height) || other.height == height)&&const DeepCollectionEquality().equals(other.certificate, certificate));
}


@override
int get hashCode => Object.hash(runtimeType,width,height,const DeepCollectionEquality().hash(certificate));

@override
String toString() {
  return 'RdpEvent.connected(width: $width, height: $height, certificate: $certificate)';
}


}

/// @nodoc
abstract mixin class $RdpEvent_ConnectedCopyWith<$Res> implements $RdpEventCopyWith<$Res> {
  factory $RdpEvent_ConnectedCopyWith(RdpEvent_Connected value, $Res Function(RdpEvent_Connected) _then) = _$RdpEvent_ConnectedCopyWithImpl;
@useResult
$Res call({
 int width, int height, Uint8List certificate
});




}
/// @nodoc
class _$RdpEvent_ConnectedCopyWithImpl<$Res>
    implements $RdpEvent_ConnectedCopyWith<$Res> {
  _$RdpEvent_ConnectedCopyWithImpl(this._self, this._then);

  final RdpEvent_Connected _self;
  final $Res Function(RdpEvent_Connected) _then;

/// Create a copy of RdpEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? width = null,Object? height = null,Object? certificate = null,}) {
  return _then(RdpEvent_Connected(
width: null == width ? _self.width : width // ignore: cast_nullable_to_non_nullable
as int,height: null == height ? _self.height : height // ignore: cast_nullable_to_non_nullable
as int,certificate: null == certificate ? _self.certificate : certificate // ignore: cast_nullable_to_non_nullable
as Uint8List,
  ));
}


}

/// @nodoc


class RdpEvent_FrameUpdate extends RdpEvent {
  const RdpEvent_FrameUpdate({required this.x, required this.y, required this.width, required this.height, required this.pixels}): super._();
  

 final  int x;
 final  int y;
 final  int width;
 final  int height;
 final  Uint8List pixels;

/// Create a copy of RdpEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RdpEvent_FrameUpdateCopyWith<RdpEvent_FrameUpdate> get copyWith => _$RdpEvent_FrameUpdateCopyWithImpl<RdpEvent_FrameUpdate>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RdpEvent_FrameUpdate&&(identical(other.x, x) || other.x == x)&&(identical(other.y, y) || other.y == y)&&(identical(other.width, width) || other.width == width)&&(identical(other.height, height) || other.height == height)&&const DeepCollectionEquality().equals(other.pixels, pixels));
}


@override
int get hashCode => Object.hash(runtimeType,x,y,width,height,const DeepCollectionEquality().hash(pixels));

@override
String toString() {
  return 'RdpEvent.frameUpdate(x: $x, y: $y, width: $width, height: $height, pixels: $pixels)';
}


}

/// @nodoc
abstract mixin class $RdpEvent_FrameUpdateCopyWith<$Res> implements $RdpEventCopyWith<$Res> {
  factory $RdpEvent_FrameUpdateCopyWith(RdpEvent_FrameUpdate value, $Res Function(RdpEvent_FrameUpdate) _then) = _$RdpEvent_FrameUpdateCopyWithImpl;
@useResult
$Res call({
 int x, int y, int width, int height, Uint8List pixels
});




}
/// @nodoc
class _$RdpEvent_FrameUpdateCopyWithImpl<$Res>
    implements $RdpEvent_FrameUpdateCopyWith<$Res> {
  _$RdpEvent_FrameUpdateCopyWithImpl(this._self, this._then);

  final RdpEvent_FrameUpdate _self;
  final $Res Function(RdpEvent_FrameUpdate) _then;

/// Create a copy of RdpEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? x = null,Object? y = null,Object? width = null,Object? height = null,Object? pixels = null,}) {
  return _then(RdpEvent_FrameUpdate(
x: null == x ? _self.x : x // ignore: cast_nullable_to_non_nullable
as int,y: null == y ? _self.y : y // ignore: cast_nullable_to_non_nullable
as int,width: null == width ? _self.width : width // ignore: cast_nullable_to_non_nullable
as int,height: null == height ? _self.height : height // ignore: cast_nullable_to_non_nullable
as int,pixels: null == pixels ? _self.pixels : pixels // ignore: cast_nullable_to_non_nullable
as Uint8List,
  ));
}


}

/// @nodoc


class RdpEvent_Clipboard extends RdpEvent {
  const RdpEvent_Clipboard({required this.text}): super._();
  

 final  String text;

/// Create a copy of RdpEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RdpEvent_ClipboardCopyWith<RdpEvent_Clipboard> get copyWith => _$RdpEvent_ClipboardCopyWithImpl<RdpEvent_Clipboard>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RdpEvent_Clipboard&&(identical(other.text, text) || other.text == text));
}


@override
int get hashCode => Object.hash(runtimeType,text);

@override
String toString() {
  return 'RdpEvent.clipboard(text: $text)';
}


}

/// @nodoc
abstract mixin class $RdpEvent_ClipboardCopyWith<$Res> implements $RdpEventCopyWith<$Res> {
  factory $RdpEvent_ClipboardCopyWith(RdpEvent_Clipboard value, $Res Function(RdpEvent_Clipboard) _then) = _$RdpEvent_ClipboardCopyWithImpl;
@useResult
$Res call({
 String text
});




}
/// @nodoc
class _$RdpEvent_ClipboardCopyWithImpl<$Res>
    implements $RdpEvent_ClipboardCopyWith<$Res> {
  _$RdpEvent_ClipboardCopyWithImpl(this._self, this._then);

  final RdpEvent_Clipboard _self;
  final $Res Function(RdpEvent_Clipboard) _then;

/// Create a copy of RdpEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? text = null,}) {
  return _then(RdpEvent_Clipboard(
text: null == text ? _self.text : text // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class RdpEvent_ClipboardTransfer extends RdpEvent {
  const RdpEvent_ClipboardTransfer({required this.sending, required this.fileName, required this.index, required this.fileCount, required this.transferred, required this.total, required this.complete}): super._();
  

 final  bool sending;
 final  String fileName;
 final  int index;
 final  int fileCount;
 final  BigInt transferred;
 final  BigInt total;
 final  bool complete;

/// Create a copy of RdpEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RdpEvent_ClipboardTransferCopyWith<RdpEvent_ClipboardTransfer> get copyWith => _$RdpEvent_ClipboardTransferCopyWithImpl<RdpEvent_ClipboardTransfer>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RdpEvent_ClipboardTransfer&&(identical(other.sending, sending) || other.sending == sending)&&(identical(other.fileName, fileName) || other.fileName == fileName)&&(identical(other.index, index) || other.index == index)&&(identical(other.fileCount, fileCount) || other.fileCount == fileCount)&&(identical(other.transferred, transferred) || other.transferred == transferred)&&(identical(other.total, total) || other.total == total)&&(identical(other.complete, complete) || other.complete == complete));
}


@override
int get hashCode => Object.hash(runtimeType,sending,fileName,index,fileCount,transferred,total,complete);

@override
String toString() {
  return 'RdpEvent.clipboardTransfer(sending: $sending, fileName: $fileName, index: $index, fileCount: $fileCount, transferred: $transferred, total: $total, complete: $complete)';
}


}

/// @nodoc
abstract mixin class $RdpEvent_ClipboardTransferCopyWith<$Res> implements $RdpEventCopyWith<$Res> {
  factory $RdpEvent_ClipboardTransferCopyWith(RdpEvent_ClipboardTransfer value, $Res Function(RdpEvent_ClipboardTransfer) _then) = _$RdpEvent_ClipboardTransferCopyWithImpl;
@useResult
$Res call({
 bool sending, String fileName, int index, int fileCount, BigInt transferred, BigInt total, bool complete
});




}
/// @nodoc
class _$RdpEvent_ClipboardTransferCopyWithImpl<$Res>
    implements $RdpEvent_ClipboardTransferCopyWith<$Res> {
  _$RdpEvent_ClipboardTransferCopyWithImpl(this._self, this._then);

  final RdpEvent_ClipboardTransfer _self;
  final $Res Function(RdpEvent_ClipboardTransfer) _then;

/// Create a copy of RdpEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? sending = null,Object? fileName = null,Object? index = null,Object? fileCount = null,Object? transferred = null,Object? total = null,Object? complete = null,}) {
  return _then(RdpEvent_ClipboardTransfer(
sending: null == sending ? _self.sending : sending // ignore: cast_nullable_to_non_nullable
as bool,fileName: null == fileName ? _self.fileName : fileName // ignore: cast_nullable_to_non_nullable
as String,index: null == index ? _self.index : index // ignore: cast_nullable_to_non_nullable
as int,fileCount: null == fileCount ? _self.fileCount : fileCount // ignore: cast_nullable_to_non_nullable
as int,transferred: null == transferred ? _self.transferred : transferred // ignore: cast_nullable_to_non_nullable
as BigInt,total: null == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as BigInt,complete: null == complete ? _self.complete : complete // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class RdpEvent_Disconnected extends RdpEvent {
  const RdpEvent_Disconnected({required this.reason}): super._();
  

 final  String reason;

/// Create a copy of RdpEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RdpEvent_DisconnectedCopyWith<RdpEvent_Disconnected> get copyWith => _$RdpEvent_DisconnectedCopyWithImpl<RdpEvent_Disconnected>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RdpEvent_Disconnected&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,reason);

@override
String toString() {
  return 'RdpEvent.disconnected(reason: $reason)';
}


}

/// @nodoc
abstract mixin class $RdpEvent_DisconnectedCopyWith<$Res> implements $RdpEventCopyWith<$Res> {
  factory $RdpEvent_DisconnectedCopyWith(RdpEvent_Disconnected value, $Res Function(RdpEvent_Disconnected) _then) = _$RdpEvent_DisconnectedCopyWithImpl;
@useResult
$Res call({
 String reason
});




}
/// @nodoc
class _$RdpEvent_DisconnectedCopyWithImpl<$Res>
    implements $RdpEvent_DisconnectedCopyWith<$Res> {
  _$RdpEvent_DisconnectedCopyWithImpl(this._self, this._then);

  final RdpEvent_Disconnected _self;
  final $Res Function(RdpEvent_Disconnected) _then;

/// Create a copy of RdpEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? reason = null,}) {
  return _then(RdpEvent_Disconnected(
reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class RdpEvent_Error extends RdpEvent {
  const RdpEvent_Error({required this.message}): super._();
  

 final  String message;

/// Create a copy of RdpEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RdpEvent_ErrorCopyWith<RdpEvent_Error> get copyWith => _$RdpEvent_ErrorCopyWithImpl<RdpEvent_Error>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RdpEvent_Error&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode => Object.hash(runtimeType,message);

@override
String toString() {
  return 'RdpEvent.error(message: $message)';
}


}

/// @nodoc
abstract mixin class $RdpEvent_ErrorCopyWith<$Res> implements $RdpEventCopyWith<$Res> {
  factory $RdpEvent_ErrorCopyWith(RdpEvent_Error value, $Res Function(RdpEvent_Error) _then) = _$RdpEvent_ErrorCopyWithImpl;
@useResult
$Res call({
 String message
});




}
/// @nodoc
class _$RdpEvent_ErrorCopyWithImpl<$Res>
    implements $RdpEvent_ErrorCopyWith<$Res> {
  _$RdpEvent_ErrorCopyWithImpl(this._self, this._then);

  final RdpEvent_Error _self;
  final $Res Function(RdpEvent_Error) _then;

/// Create a copy of RdpEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? message = null,}) {
  return _then(RdpEvent_Error(
message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
