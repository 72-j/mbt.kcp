// codec_port.mbt — MDS 纠删编解码端口(K8 刀3;六边形:数学内核住端口外侧)
//
// FEC 层机器只认此端口——RS 是缺省适配器,将来 XOR 快径(m=1)或其他
// 纠删码即插即换,层机器零改动(大gen 律:换码 = 换数据/适配器,不换机器)。

///|
/// MDS 端口:k 数据片 + m 冗余片,任意 ≤m 片抹除可恢复;片等长。
pub(open) trait MdsCodec {
  fn encode_parity(Self, Array[FixedArray[Byte]]) -> Array[FixedArray[Byte]]
  fn recover(Self, Array[FixedArray[Byte]?]) -> Array[FixedArray[Byte]]?
}

///|
/// RS 缺省适配器:直委刀2 固有实现(全限定调用,免撞名歧义)。

///|
impl MdsCodec for RsCodec with fn encode_parity(
  self : RsCodec,
  data : Array[FixedArray[Byte]],
) -> Array[FixedArray[Byte]] {
  RsCodec::encode_parity(self, data)
}

///|
impl MdsCodec for RsCodec with fn recover(
  self : RsCodec,
  slots : Array[FixedArray[Byte]?],
) -> Array[FixedArray[Byte]]? {
  RsCodec::recover(self, slots)
}
