// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'distance_item.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class DistanceItemAdapter extends TypeAdapter<DistanceItem> {
  @override
  final int typeId = 0;

  @override
  DistanceItem read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return DistanceItem(
      id: fields[0] as String,
      volume: fields[2] as double,
      label: fields[1] as String,
    );
  }

  @override
  void write(BinaryWriter writer, DistanceItem obj) {
    writer
      ..writeByte(3)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.label)
      ..writeByte(2)
      ..write(obj.volume);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DistanceItemAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
