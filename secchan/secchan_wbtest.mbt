// secchan_wbtest.mbt — secchan 罐(白盒:window_probe 私件直用)
// 罐单(茗篇 §六):窗口四形/记录层往返+篡改/滑窗重放乱序远跳/PSK-CR
// 对打+错 psk/wire 往返+错序/方向钥分离+端到端迷你对打

///|
let sec_psk : Bytes = Bytes::make(32, b'\x50')

///|
fn nonces() -> (Bytes, Bytes) {
  (Bytes::make(16, b'\x01'), Bytes::make(16, b'\x02'))
}

///|
test "窗口探针四形:单调收/重放拒/窗外拒/乱序窗内收" {
  // 单调首包(seq 0 保留,1 起步)
  let (ok, h, b) = window_probe(0UL, 0UL, 1UL)
  assert_true(ok)
  assert_eq(h, 1UL)
  assert_eq(b, 1UL)
  // 重放:最高位已在窗
  let (ok2, _, _) = window_probe(h, b, 1UL)
  assert_true(ok2 == false)
  // 单调推进 → bits 0b11
  let (ok3, h3, b3) = window_probe(h, b, 2UL)
  assert_true(ok3)
  assert_eq(h3, 2UL)
  assert_eq(b3, 3UL)
  // 远跳:highest 直上 67,bits 清位
  let (_, h4, b4) = window_probe(h3, b3, 67UL)
  assert_eq(h4, 67UL)
  // 窗外老包:back=65 ≥ 64 拒
  let (ok5, _, _) = window_probe(h4, b4, 2UL)
  assert_true(ok5 == false)
  // 乱序窗内:back=2 未标记,收
  let (ok6, _, _) = window_probe(h4, b4, 65UL)
  assert_true(ok6)
}

///|
test "记录层:往返/篡改 ct 拒/aad 错拒" {
  let sealer = Sealer::new(key=Bytes::make(32, b'\x61'))
  let opener = Opener::new(key=Bytes::make(32, b'\x61'))
  let aad = b"conv7|push"
  let record = sealer.seal(aad~, plaintext=b"hello secchan")
  match opener.open(aad~, record~) {
    Some(pt) => assert_eq(pt, b"hello secchan")
    None => abort("往返应绿")
  }
  // 篡改 ct(第 9 字节起)
  let broken = Bytes::makei(record.length(), fn(i) {
    if i == 9 {
      (record[i].to_int() ^ 1).to_byte()
    } else {
      record[i]
    }
  })
  assert_true(opener.open(aad~, record=broken) is None)
  // aad 不对 → None(D-S5 绑定)
  assert_true(opener.open(aad=b"conv8|push", record~) is None)
}

///|
test "滑窗:重放拒/乱序窗内收/远跳后窗外拒" {
  let sealer = Sealer::new(key=Bytes::make(32, b'\x62'))
  let opener = Opener::new(key=Bytes::make(32, b'\x62'))
  let records : Array[Bytes] = []
  for _i in 0..<5 {
    records.push(sealer.seal(aad=b"", plaintext=b"p"))
  }
  // 乱序:3 → 1 → 2 窗内全收
  assert_true(opener.open(aad=b"", record=records[2]) is Some(_))
  assert_true(opener.open(aad=b"", record=records[0]) is Some(_))
  assert_true(opener.open(aad=b"", record=records[1]) is Some(_))
  // 重放 records[2] → None
  assert_true(opener.open(aad=b"", record=records[2]) is None)
  // 远跳 70 包:开第 70 后,第 1 包 back=69 ≥ 64 拒
  let far = Sealer::new(key=Bytes::make(32, b'\x62'))
  let far_open = Opener::new(key=Bytes::make(32, b'\x62'))
  let mut first : Bytes = b""
  let mut last : Bytes = b""
  for _i in 0..<70 {
    let r = far.seal(aad=b"", plaintext=b"x")
    if first.length() == 0 {
      first = r
    }
    last = r
  }
  assert_true(far_open.open(aad=b"", record=last) is Some(_))
  assert_true(far_open.open(aad=b"", record=first) is None)
}

///|
test "PSK-CR 双方对打:keys 相等且方向钥分离" {
  let (cn, sn) = nonces()
  let (hello, client) = pskcr_client_start(psk=sec_psk, client_nonce=cn)
  let (salt, server) = match
    pskcr_server_on_hello(psk=sec_psk, server_nonce=sn, msg=hello) {
    Ok(pair) => pair
    Err(_) => abort("server HELLO 应绿")
  }
  let (auth, ckeys) = match client.on_salt(msg=salt) {
    Ok(pair) => pair
    Err(_) => abort("客户端应绿")
  }
  let skeys = match server.on_auth(msg=auth) {
    Ok(k) => k
    Err(_) => abort("服务端应绿")
  }
  assert_eq(ckeys, skeys)
  assert_eq(ckeys.key_c2s.length(), 32)
  assert_true(ckeys.key_c2s != ckeys.key_s2c)
}

///|
test "错 psk:AuthFail" {
  let (cn, sn) = nonces()
  let (hello, client) = pskcr_client_start(
    psk=Bytes::make(32, b'\x01'),
    client_nonce=cn,
  )
  let (salt, server) = match
    pskcr_server_on_hello(
      psk=Bytes::make(32, b'\x02'),
      server_nonce=sn,
      msg=hello,
    ) {
    Ok(pair) => pair
    Err(_) => abort("server HELLO 应绿")
  }
  let (auth, _) = match client.on_salt(msg=salt) {
    Ok(pair) => pair
    Err(_) => abort("客户端应绿")
  }
  match server.on_auth(msg=auth) {
    Err(PskCrErr::AuthFail) => ()
    _ => abort("应 AuthFail")
  }
}

///|
test "wire 往返:三消息 + 错 tag None + 错序 BadState" {
  let (cn, sn) = nonces()
  let (hello, _) = pskcr_client_start(psk=sec_psk, client_nonce=cn)
  match PskCrMsg::of_wire(hello.to_wire()) {
    Some(PskCrMsg::Hello(n)) => assert_eq(n, cn)
    _ => abort("HELLO wire 往返应绿")
  }
  match PskCrMsg::of_wire(PskCrMsg::Salt(sn).to_wire()) {
    Some(PskCrMsg::Salt(n)) => assert_eq(n, sn)
    _ => abort("SALT wire 往返应绿")
  }
  // 错 tag
  assert_true(PskCrMsg::of_wire(b"\x09") is None)
  // 错序:服务端首包喂 SALT 型消息 → BadState
  match
    pskcr_server_on_hello(psk=sec_psk, server_nonce=sn, msg=PskCrMsg::Salt(sn)) {
    Err(PskCrErr::BadState(_)) => ()
    _ => abort("应 BadState")
  }
}

///|
test "方向钥分离 + 端到端迷你对打" {
  let (cn, sn) = nonces()
  let (hello, client) = pskcr_client_start(psk=sec_psk, client_nonce=cn)
  let (salt, server) = match
    pskcr_server_on_hello(psk=sec_psk, server_nonce=sn, msg=hello) {
    Ok(pair) => pair
    Err(_) => abort("server HELLO 应绿")
  }
  let (auth, ckeys) = match client.on_salt(msg=salt) {
    Ok(pair) => pair
    Err(_) => abort("客户端应绿")
  }
  let skeys = match server.on_auth(msg=auth) {
    Ok(k) => k
    Err(_) => abort("服务端应绿")
  }
  let cside = SecSession::client(keys=ckeys)
  let sside = SecSession::server(keys=skeys)
  // c → s
  let rec = cside.seal(aad=b"conv1", plaintext=b"ping")
  match sside.open(aad=b"conv1", record=rec) {
    Some(pt) => assert_eq(pt, b"ping")
    None => abort("c2s 应绿")
  }
  // s → c
  let back = sside.seal(aad=b"conv1", plaintext=b"pong")
  match cside.open(aad=b"conv1", record=back) {
    Some(pt) => assert_eq(pt, b"pong")
    None => abort("s2c 应绿")
  }
  // 方向分离:s2c 密文喂给 c2s 开启器 → 解密败 → None
  let wrong_dir = sside.seal(aad=b"conv1", plaintext=b"x")
  assert_true(sside.open(aad=b"conv1", record=wrong_dir) is None)
}
