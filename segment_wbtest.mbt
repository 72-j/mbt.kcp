// segment_wbtest.mbt — K1 门:编解码往返 + 边界

///|
fn mk_seg(
  conv : Int32,
  cmd : Int32,
  sn : Int32,
  text_len : Int32,
) -> KcpSegment {
  let data = Bytes::makei(text_len, fn(i) { (65 + i).to_byte() })
  {
    conv,
    cmd,
    frg: 0,
    wnd: 32,
    ts: 1700000000,
    sn,
    una: 0,
    len: text_len,
    data,
    xmit: 0,
    fastack: 0,
    resendts: 0,
    rto: 0,
  }
}

///|
test "roundtrip full fields" {
  let seg = mk_seg(0x12345678, CMD_PUSH, 1, 5)
  let encoded = encode_segment(seg)
  assert_eq(encoded.length(), HEADER_SIZE + 5)
  let result = decode_segment(encoded, 0)
  assert_true(result is Some(_))
  let (d, used) = unwrap_opt(result)
  assert_eq(used, HEADER_SIZE + 5)
  assert_eq(d.conv, 0x12345678)
  assert_eq(d.cmd, CMD_PUSH)
  assert_eq(d.sn, 1)
}

///|
test "empty data" {
  let seg = mk_seg(1, CMD_ACK, 1, 0)
  let encoded = encode_segment(seg)
  let (d, _) = decode_segment(encoded, 0) |> unwrap_opt
  assert_eq(d.data.length(), 0)
}

///|
test "short buf None" {
  let buf = Bytes::make(10, 0b0)
  assert_true(decode_segment(buf, 0) is None)
}

///|
test "len overrun None" {
  // 28 字节零帧,len 字段(字节 20..23)= 10 > 剩余 ⇒ None
  let buf = Bytes::makei(28, fn(i) {
    if i == 20 {
      (10).to_byte()
    } else {
      0b0
    }
  })
  assert_true(decode_segment(buf, 0) is None)
}

///|
test "sequential decode" {
  let s1 = mk_seg(1, CMD_PUSH, 1, 3)
  let s2 = mk_seg(1, CMD_ACK, 2, 0)
  let e1 = encode_segment(s1)
  let e2 = encode_segment(s2)
  let len1 = e1.length()
  let combined = Bytes::makei(len1 + e2.length(), fn(i) {
    if i < len1 {
      e1[i]
    } else {
      e2[i - len1]
    }
  })
  let (d1, u1) = decode_segment(combined, 0) |> unwrap_opt
  assert_eq(d1.sn, 1)
  let (d2, _) = decode_segment(combined, u1) |> unwrap_opt
  assert_eq(d2.sn, 2)
}

///|
fn unwrap_opt(opt : (KcpSegment, Int32)?) -> (KcpSegment, Int32) {
  match opt {
    Some(pair) => pair
    None => abort("unwrap None")
  }
}
