# network-multitool 转发性能基准测试

使用 `iperf3` 对本目录下的四种拓扑 (`bridge-lab`、`bridge2-lab`、`route-lab`、`route2-lab`) 进行端到端吞吐量测试,评估 Linux 容器在不同转发模式(二层桥接 vs 三层路由)及不同跳数下的性能表现,并通过对照实验量化 `br_netfilter` 对桥接性能的影响。

## 测试环境

- **容器镜像**: `ghcr.io/srl-labs/network-multitool`
- **部署工具**: `containerlab`
- **测试工具**: `iperf3` (TCP,单流,10 秒)
- **自动化脚本**: [`bench.sh`](./bench.sh)
- **基准(本机上限)**: iperf3 在宿主机本地 loopback 测得 **44 Gbps**,作为理论天花板参考。

### 测试命令

```bash
# 在 server 端
docker exec -it client2 iperf3 -s

# 在 client 端
docker exec -it client1 iperf3 -c <client2-ip>
```

或者直接用一键脚本:

```bash
./bench.sh                 # 顺序跑 4 个 lab
DURATION=30 ./bench.sh     # 自定义时长
```

## 测试结果

| 场景 | 拓扑模型 | 跳数 | 转发方式 | 吞吐量 | 相对基准 |
|---|---|---:|---|---:|---:|
| **本机** | loopback | 0 | 内核直通 | **44.0 Gbps** | 100% |
| **bridge** (brnf=1) | `client1 — spine1 — client2` | 1 | L2 bridge | **18.1 Gbps** | 41.1% |
| **bridge** (brnf=0) | 同上,关闭 br_netfilter | 1 | L2 bridge | **21.6 Gbps** | 49.1% |
| **bridge2** (brnf=1) | `client1 — leaf1 — spine1 — leaf2 — client2` | 3 | L2 bridge × 3 | **12.7 Gbps** | 28.9% |
| **bridge2** (brnf=0) | 同上,关闭 br_netfilter | 3 | L2 bridge × 3 | **18.8 Gbps** | 42.7% |
| **route** | `client1 — router — client2` | 1 | L3 路由 | **18.9 Gbps** | 43.0% |
| **route2** | `client1 — leaf1 — router — leaf2 — client2` | 3 | L3 路由 + 2 次 NAT | **13.3 Gbps** | 30.2% |

## 结果分析

### 1. 容器虚拟化本身损耗巨大

即便只经过一跳中间容器,吞吐量也从 44 Gbps 跌到 18~21 Gbps(约 **50~60% 的损耗**)。
主要来自 `veth pair` 的上下文切换、两次内核协议栈穿越,以及 namespace 隔离带来的开销。

### 2. `br_netfilter` 是桥接慢的主因

这是本次测试最有价值的发现:

| 场景 | brnf=1 | brnf=0 | 提升 |
|---|---:|---:|---:|
| bridge(1 跳) | 18.1 Gbps | 21.6 Gbps | **+19.3%** |
| bridge2(3 跳) | 12.7 Gbps | 18.8 Gbps | **+48.0%** |

- 单跳就能收回约 20% 性能,**三跳更是直接涨了 48%**(几乎让三跳桥接追平单跳桥接的默认性能)。
- 原因:`br_netfilter` 的开销是 **按包 × 按跳数** 叠加的。每经过一个桥,每个帧都要:
  1. `skb_pull()` 剥以太网头
  2. 分配 `nf_bridge_info` 结构体
  3. 穿越 IP 层 netfilter hook chain(即便规则是空的)
  4. 走一遍 conntrack 查表
  5. `skb_push()` 把以太网头加回来
- 跳数越多,`br_netfilter` 的 "按包税" 累积得越狠,这也就是为什么 bridge2 的提升比 bridge 大得多。

### 3. 关闭 `br_netfilter` 后,bridge 反超 route

| 对比 | bridge | route |
|---|---:|---:|
| 单跳(brnf=1) | 18.1 | 18.9 |
| 单跳(brnf=0) | **21.6** | 18.9 |
| 三跳(brnf=1) | 12.7 | 13.3 |
| 三跳(brnf=0) | **18.8** | 13.3 |

- 默认配置下 route 略快于 bridge —— 这是 `br_netfilter` 拖累的。
- 一旦关闭 `br_netfilter`,bridge 明显优于 route(单跳快 14%,三跳快 41%)。
- 这符合理论预期:**纯 L2 桥接的代码路径本来就比 L3 路由短**,无需改 TTL、无需重算 IP checksum、无需查 FIB。只是默认情况下被 `br_netfilter` 拖累了。

### 4. 每跳开销定量

以 brnf=0 的"干净"数据做参考,更接近桥接/路由的"真实代价":

| 转发方式 | 单跳 | 三跳 | 下降 | 近似每跳损耗 |
|---|---:|---:|---:|---:|
| L2 bridge (brnf=0) | 21.6 | 18.8 | -13.0% | ~6.5% / 跳 |
| L3 route | 18.9 | 13.3 | -29.6% | ~15% / 跳 |

- 桥接的"纯转发成本"很低,每跳只掉 6~7%。
- 路由的每跳损耗更高,因为多一层 IP 处理(TTL 减、checksum、FIB 查找),而且 route2 场景还有 2 次 NAT 带来的 conntrack 状态维护。

## 简易性能排序

```
本机 (44.0G)
  ▼
bridge-brnf0 (21.6G) > route (18.9G) > bridge2-brnf0 (18.8G) ≈ bridge-brnf1 (18.1G)
  ▼
route2 (13.3G) > bridge2-brnf1 (12.7G)
```

## 结论与建议

1. **`br_netfilter` 是软件桥接性能的隐藏杀手**。即使 iptables 规则为空,它仍会带来 20~50% 的损耗,且随跳数线性放大。
2. **如果不需要对桥接流量做 iptables 过滤,务必关闭**:
   ```bash
   sysctl -w net.bridge.bridge-nf-call-iptables=0
   sysctl -w net.bridge.bridge-nf-call-ip6tables=0
   sysctl -w net.bridge.bridge-nf-call-arptables=0
   ```
   这也是 Cilium、Calico eBPF 模式等云原生数据面默认要求的设置。
3. **单纯拼转发性能,L2 bridge(关 `br_netfilter`)> L3 route**;有 NAT / 路由过滤需求才考虑 L3。
4. 对性能敏感的实验应 **尽量减少中间跳数**,容器软件转发每一跳都是实打实的开销。
5. 本测试只反映 **容器软件转发性能**,不代表真实网络设备或 SR Linux / OpenWRT 等专用 NOS 的行为。
6. 进一步可以追加:
   - `iperf3 -P 8`(多流,观察多核扩展)
   - `iperf3 -u -b 0`(UDP,观察小包 PPS)
   - 对比 `--link mode=veth` vs `macvlan` / `ipvlan` 的性能

## 附录:如何复现

```bash
cd muiltitool

# 一键跑 4 个 lab(推荐)
./bench.sh

# 手动流程
sudo containerlab deploy -t bridge-lab.clab.yml
docker exec -d client2 iperf3 -s -1
docker exec -it client1 iperf3 -c 192.168.0.2 -t 10
sudo containerlab destroy -t bridge-lab.clab.yml --cleanup

# 对照实验:关闭 br_netfilter
for n in spine1 leaf1 leaf2; do
  docker exec "$n" sysctl -w net.bridge.bridge-nf-call-iptables=0
done
```
