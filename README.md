# Egress audit for a local AI stack

This repository holds the egress audit from the article "Is Your Offline AI Stack Truly Offline?" It cuts a local Retrieval-Augmented Generation (RAG) stack off from the network, records every outbound attempt the stack still makes, and attributes each attempt to the component that made it.

Use it to check what your own on-prem AI stack does on the network before you call it air-gapped.

## What the audit does

The audit cuts the network without unplugging anything. Unplugged tools give up before they send a packet, which leaves nothing to record. Instead, two controls keep the network interface up and block traffic:

- **A deny-all egress firewall** (`audit/egress-deny.sh`). Rules go in Docker's `DOCKER-USER` chain. Traffic between the stack's containers is allowed, and so are replies to connections started outside the stack, such as a browser opening a component's UI. Every other packet leaving the stack network is logged with the prefix `EGRESS-BLOCK` and rejected.
- **A logging DNS sinkhole** (`docker-compose.audit.yml`, `audit/dns/`). A dnsmasq container logs every hostname the stack looks up and answers every external name with `198.51.100.1`, an address reserved for documentation (RFC 5737). Nothing is forwarded upstream. A component that looks up a host gets an answer, tries to connect, and hits the firewall.

Each component has a fixed address on the stack network, so every attempt can be attributed.

### Three records, none complete on its own

| Record | Shows | Misses |
| --- | --- | --- |
| DNS sinkhole log | Every hostname a component tried to resolve, and who asked | Connections to hard-coded IP addresses |
| Packet capture (`tcpdump` on `br-rag`) | Every packet a component put on the stack network | Lookups that never resolve, host traffic, anything outside the capture window |
| Firewall log (kernel log) | Every packet the firewall blocked | Messages the kernel rate-limits, or everything if the LOG target is unavailable |

Report every finding with the records that show it. A finding in two or more records is corroborated. A finding in one record is still reported, with that limit stated.

All three records miss traffic from the host itself, requests from a browser on another machine, encrypted payload contents, and anything outside the run's actions and time window. State these limits wherever you publish results.

## Repository layout

```text
.
├── README.md
├── docker-compose.yml          # Test stack, pinned by image digest, with fixed addresses
├── docker-compose.audit.yml    # Audit overlay: DNS sinkhole and per-service DNS settings
├── Dockerfile                  # App image (Python 3.12)
├── requirements.txt            # Every Python package, pinned
├── rag.py                      # Minimal RAG pipeline used as the test subject
├── docs/                       # Sample documents the pipeline ingests
├── audit/
│   ├── egress-deny.sh          # Deny-all egress policy: on, off, status
│   ├── summarize.sh            # Reports the three records side by side
│   └── dns/
│       ├── Dockerfile
│       └── dnsmasq.conf
└── capture/                    # Run output lands here
```

## Test stack

| Component | Role | Version |
| --- | --- | --- |
| Actian VectorAI DB Community Edition | Vector database | 1.0.3 |
| Ollama with `llama3.2:3b` | Model server and language model | 0.40.3 |
| `BAAI/bge-small-en-v1.5` via sentence-transformers | Embedding model | sentence-transformers 5.7.0 |
| LlamaIndex | RAG framework | `llama-index-core` 0.14.25 |
| Arize Phoenix | Tracing and observability | 20.21.1 |

Every component runs with its defaults. The stack runs as written in the official docs, so the audit measures what a typical deployment does on day one.

Component addresses on the stack network:

| Component | Address |
| --- | --- |
| vectorai | 10.77.0.10 |
| ollama | 10.77.0.11 |
| phoenix | 10.77.0.12 |
| app | 10.77.0.20 |
| dns-sinkhole | 10.77.0.53 |
| Docker's DNS forwarder | 10.77.0.1 |

## Requirements

- A Linux host with Docker Engine and the Compose plugin
- `iptables`, `tcpdump`, and `sudo`
- About 12 GB of memory for the full stack
- Network access for the first setup, to pull images and the model

Tested on Ubuntu 24.04 running under WSL2 with Docker Engine installed inside Ubuntu. Docker Desktop is not supported for the capture, because it runs containers in a separate system the firewall rules and capture can't reach.

## 1. Set up the stack (network open)

```bash
mkdir -p local_data ollama_data phoenix_data hf_cache model_cache
sudo chown -R 999:999 local_data
docker compose up -d
docker exec ollama ollama pull llama3.2:3b
docker compose build app
docker compose run --rm app --question "How long are adult patient records kept?"
```

The question should return an answer drawn from `docs/`. VectorAI DB runs as user 999 inside its container, so it needs to own its data folder.

## 2. Install and test the audit (network open)

Run every command from the repository root. Open two terminals, one for the stack and one for the packet capture, and set this in each:

```bash
export COMPOSE_FILE=docker-compose.yml:docker-compose.audit.yml
```

Build the sinkhole and start the stack with it:

```bash
docker compose build dns
docker compose up -d
```

Test the sinkhole. The answer should be `198.51.100.1`:

```bash
docker compose run --rm --entrypoint python app -c "import socket; print(socket.gethostbyname('huggingface.co'))"
sudo cat capture/dns.log
```

Test the firewall. The `on` command should print `Firewall-level logging: enabled`, and the connection should fail at once with `ConnectionRefusedError`:

```bash
sudo ./audit/egress-deny.sh on
docker compose run --rm --entrypoint python app -c "import socket; socket.create_connection(('1.1.1.1', 443), timeout=5)"
sudo ./audit/egress-deny.sh status
sudo dmesg | grep EGRESS-BLOCK | tail -3
sudo ./audit/egress-deny.sh off
```

If the firewall reports `UNAVAILABLE`, your kernel lacks the iptables LOG target. Blocking still works, but record the missing firewall log in your results.

## 3. Pre-staged run: runtime calls

The model, embedding model, and database are already in place, the way an air-gapped site installs from approved media. This run shows what the stack calls at runtime and whether it still answers.

Warm the caches with the network open. `-f docker-compose.yml` runs the app without the sinkhole so downloads can complete:

```bash
sudo ./audit/egress-deny.sh off
docker compose -f docker-compose.yml run --rm app --question "How long are adult patient records kept?"
sudo ls model_cache
```

`model_cache` should contain a `models--BAAI--bge-small-en-v1.5` folder. LlamaIndex stores the embedding model in its own cache folder, separate from Hugging Face's usual location, which is why the compose file keeps both.

Terminal 1:

```bash
docker compose down
docker compose up --no-start
sudo ./audit/egress-deny.sh on
sudo truncate -s 0 capture/dns.log
sudo dmesg -C
```

Check that `egress-deny.sh` printed `Firewall-level logging: enabled`. `dmesg -C` clears the kernel log so it only holds this run.

Terminal 2 (leave it running):

```bash
sudo tcpdump -i br-rag -nn -s 0 -w capture/prestaged.pcap 2>&1 | tee -i capture/prestaged.tcpdump.txt
```

Terminal 1:

```bash
docker compose up -d
docker compose run --rm app --question "How long are adult patient records kept?"
```

When the answer prints, leave the stack idle so calls on a timer can fire:

```bash
sleep 1800
```

Then press Ctrl+C in Terminal 2, and in Terminal 1:

```bash
sudo cp capture/dns.log capture/prestaged.dns.log
sudo TZ=UTC dmesg --time-format iso > capture/prestaged.kernel.log
sudo ./audit/summarize.sh capture/prestaged | tee capture/prestaged.summary.txt
```

Save the component logs before you stop the stack, because `docker compose down` deletes them:

```bash
docker logs vectorai > capture/prestaged-vectorai.log 2>&1
docker logs ollama > capture/prestaged-ollama.log 2>&1
docker logs phoenix > capture/prestaged-phoenix.log 2>&1
```

Expect the question to take several minutes. Some libraries retry each blocked check before falling back to their cache.

## 4. Cold-start run: setup-time calls

Caches and data are moved aside, so the stack has to fetch everything. This run shows the setup-time calls.

Terminal 1:

```bash
docker compose down
sudo mv ollama_data ollama_data.warm && mkdir ollama_data
sudo mv hf_cache hf_cache.warm && mkdir hf_cache
sudo mv model_cache model_cache.warm && mkdir model_cache
sudo mv phoenix_data phoenix_data.warm && mkdir phoenix_data
sudo mv local_data local_data.warm && mkdir local_data && sudo chown -R 999:999 local_data
docker compose up --no-start
sudo ./audit/egress-deny.sh on
sudo truncate -s 0 capture/dns.log
sudo dmesg -C
```

Terminal 2:

```bash
sudo tcpdump -i br-rag -nn -s 0 -w capture/cold.pcap 2>&1 | tee -i capture/cold.tcpdump.txt
```

Terminal 1. The model pull and the question are both expected to fail:

```bash
docker compose up -d
docker exec ollama ollama pull llama3.2:3b
docker compose run --rm app --question "How long are adult patient records kept?"
sleep 1800
```

Ctrl+C in Terminal 2, then:

```bash
sudo cp capture/dns.log capture/cold.dns.log
sudo TZ=UTC dmesg --time-format iso > capture/cold.kernel.log
sudo ./audit/summarize.sh capture/cold | tee capture/cold.summary.txt
```

Save the component logs before stopping the stack, because `docker compose down` deletes them:

```bash
docker logs vectorai > capture/cold-vectorai.log 2>&1
docker logs ollama > capture/cold-ollama.log 2>&1
docker logs phoenix > capture/cold-phoenix.log 2>&1
```

Component logs often name the exact URL each call was trying to reach.

## 5. Restore the working stack

```bash
docker compose down
sudo ./audit/egress-deny.sh off
sudo rm -rf ollama_data hf_cache model_cache phoenix_data local_data
sudo mv ollama_data.warm ollama_data
sudo mv hf_cache.warm hf_cache
sudo mv model_cache.warm model_cache
sudo mv phoenix_data.warm phoenix_data
sudo mv local_data.warm local_data
unset COMPOSE_FILE
docker compose up -d
```

`unset COMPOSE_FILE` drops the sinkhole, so the stack can reach the network again.

## 6. Hardened re-run: the clean log

> **Draft.** This section is being validated and will change.

Switch off each caller the earlier runs found, then repeat the pre-staged run under deny-all. A run that records no outbound attempts across the full window is the log you show an auditor.

Settings documented by each vendor:

| Component | Setting | Documented effect |
| --- | --- | --- |
| Ollama | `OLLAMA_NO_CLOUD=1` | Runs Ollama in local-only mode, without cloud features |
| Phoenix | `PHOENIX_ALLOW_EXTERNAL_RESOURCES=false` | Stops Phoenix's own public-internet requests, for air-gapped environments |
| Phoenix | `PHOENIX_TELEMETRY_ENABLED=false` | Turns off analytics tracking |
| Hugging Face libraries | `HF_HUB_OFFLINE=1` | Uses only the local cache |
| VectorAI DB | To be confirmed | |

## Reading the summary

`summarize.sh` prints four sections:

1. **DNS lookups.** Each hostname, who asked, the record type, and when it was first seen.
2. **Connection attempts leaving the stack.** From the packet capture.
3. **Firewall blocks.** From the kernel log.
4. **Coverage.** How many entries each record holds, packets the capture dropped, whether the kernel rate-limited firewall messages, and what all three records miss.

All times are UTC. The firewall log's clock can drift from the other two records, especially under WSL. Use the DNS log and component logs for timestamps, and the firewall log for counts and order.

## Adapting the audit to your own stack

1. **Put your services on one bridge network** with a fixed interface name (`com.docker.network.bridge.name`) and a fixed subnet.
2. **Give each service a fixed address** with `ipv4_address`, and add matching names to the `label()` function in `audit/summarize.sh`.
3. **Point each service's `dns` setting at the sinkhole** in an overlay file like `docker-compose.audit.yml`.
4. **Set `BRIDGE`** in `audit/egress-deny.sh` and the `-i` interface in the `tcpdump` command to your bridge name.
5. **Run your own representative workload** in place of the sample question, and keep the idle window long enough to catch calls on a timer.

## Limitations

- The policy covers the stack's container network. It does not cover the host's own traffic or IPv6.
- A single node, a small stack, and one query per run.
- Destinations are visible, but encrypted contents are not.
- A fixed observation window can't rule out calls on a longer schedule.
- This audit models one layer of an air gap. A production enclave also needs no NAT, no public DNS resolution, an internal mirror or signed media for updates, and controls at the network perimeter.
