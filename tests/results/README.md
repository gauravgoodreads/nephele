# Test reports

| Report | What it shows |
| --- | --- |
| `chaos-20261021-113206.md` | First full run: 6 of 9 passed. Exposed the node-failure scheduling bug (topology spread counted the dead node's zone). |
| `chaos-20261021-120108.md` | Run after the first fixes: exposed the Redis probe passing while Redis was still loading, and a failed request during a rolling release. |
| `chaos-20261021-140751.md` / `chaos-latest.md` | Final run, probe inside the cluster: 9 of 9 passed. |
| `ci/` | The resilience suite as run by GitHub Actions on a fresh 3-node cluster. |

Load-test results are in `loadtest/results/`.
