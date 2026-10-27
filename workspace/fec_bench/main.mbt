// workspace/fec_bench/main.mbt — FEC 开销读数(K8 刀5;留证不作门)
//
// 场景:RS(k=10,m=3) 贴视频路径——数据片 1200B;
// 读数 = 编码 MB/s(数据字节)、最坏恢复 MB/s(恰 m 抹除)、
// 帧层直通 MB/s(FecTx+头戳 + FecRx 剥头,无损路径)。
// 取时 = @async.now() 墙钟(bench_driver 同式);KB/ms 数值即 MB/s。

///|
let shard_len : Int32 = 1200

///|
let group_k : Int32 = 10

///|
let group_m : Int32 = 3

///|
let rounds : Int32 = 2000

///|
/// 数据字节总数(Int64)。
fn total_bytes() -> Int64 {
  (group_k * shard_len * rounds).to_int64()
}

///|
/// KB/ms 数值即 MB/s(bytes/ms 是 KB/s,先除 1000 归 KB)。
fn mbps(elapsed_ms : Int64) -> String {
  if elapsed_ms <= 0L {
    return "n/a(<1ms)"
  }
  "\{total_bytes() / 1000L / elapsed_ms} MB/s"
}

///|
fn make_data() -> Array[FixedArray[Byte]] {
  let shards : Array[FixedArray[Byte]] = []
  for i in 0..<group_k {
    let shard = FixedArray::make(shard_len, (0).to_byte())
    shard[0] = i.to_byte()
    shards.push(shard)
  }
  shards
}

///|
fn main {
  let codec = @fec.RsCodec::new(group_k, group_m)
  let data = make_data()
  let _ = codec.encode_parity(data) // warmup
  let parity = codec.encode_parity(data)
  let build_worst = fn() {
    // 恰 m 抹除(最坏可恢复面):数据片 0,1,2 丢,余 10 片齐
    let slots : Array[FixedArray[Byte]?] = []
    for i in 0..<group_k {
      slots.push(if i < group_m { None } else { Some(data[i]) })
    }
    for shard in parity {
      slots.push(Some(shard))
    }
    slots
  }
  let _ = codec.recover(build_worst()) // warmup
  // 帧层直通(FecTx 头戳+编码 / FecRx 剥头+投递,无损)
  let capacity = shard_len + @fec.FEC_HEADER_SIZE + 2
  let tx = @fec.FecTx::new(group_k, group_m, capacity)
  let rx = @fec.FecRx::new(8)
  let payload = FixedArray::make(shard_len, (66).to_byte())
  let pump = fn() {
    for _i in 0..<group_k {
      for frame in tx.feed(payload) {
        let _ = rx.feed(frame)
      }
    }
  }
  pump() // warmup(闭一组)
  // 逐轮 churn:输入吃 sink → 真循环携带依赖,禁 LICM 整环上提(假读数教训)
  let churn = fn(round : Int32, acc : Int64) -> Unit {
    data[round % group_k][round % shard_len] = (acc & 0xFFL).to_int().to_byte()
  }
  let t0 = @async.now()
  let mut sink : Int64 = 0L // 汇聚出口:防 DCE 削环(结果折叠+尾打印)
  for round in 0..<rounds {
    churn(round, sink)
    for shard in codec.encode_parity(data) {
      sink += shard[0].to_int().to_int64()
    }
  }
  let t1 = @async.now()
  for round in 0..<rounds {
    churn(round, sink)
    match codec.recover(build_worst()) {
      Some(fullset) => sink += fullset[0][1].to_int().to_int64()
      None => sink += 1L
    }
  }
  let t2 = @async.now()
  for round in 0..<rounds {
    churn(round, sink)
    pump()
  }
  let t3 = @async.now()
  sink += rx.stats().delivered.to_int64()
  let closed = tx.stats().closed_groups
  println(
    "fec_bench RS(\{group_k},\{group_m}) shard=\{shard_len}B rounds=\{rounds} payload=\{total_bytes() / 1048576L}MiB sink=\{sink} closed=\{closed}",
  )
  println("  encode_parity   \{mbps(t1 - t0)}")
  println("  recover(m erase) \{mbps(t2 - t1)}")
  println("  layer passthru  \{mbps(t3 - t2)}")
}
