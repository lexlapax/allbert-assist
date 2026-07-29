# Third-Party Licenses And Provenance

Best-effort inventory of known shipped components. This is not a universal SBOM, legal-compliance guarantee, or proof of ownership for every artifact byte.

This file is generated deterministically from
`apps/allbert_assist/priv/licenses/catalog.json`. Component versions and
target-specific file digests are recorded in each packaged
`THIRD-PARTY-MANIFEST.json`.

## Reviewed Dependency Inputs

Any digest change requires an explicit catalog/license disposition before
the offline drift check can pass.

| Identifier | Reviewed input | SHA-256 |
| --- | --- | --- |
| `beam-lock` | `mix.lock` | `92177f842290508a6715dec92a2e4c320dc0157ba76049e32bfd107a8412a5cc` |
| `browser-bridge-lock` | `plugins/allbert.browser/priv/playwright_bridge/package-lock.json` | `270043d292abadbe73b3928aee49a29058b3d7c90aab910065f7ef4c1fe9c1f4` |
| `web-assets-lock` | `apps/allbert_assist_web/assets/package-lock.json` | `a2478ecb898e3f8f92b08a59b64c264549dd815c76506bc697b9034156177952` |

## Required Texts

| Identifier | License ID | Reviewed source path | SHA-256 |
| --- | --- | --- | --- |
| `Apache-2.0` | `Apache-2.0` | `apps/allbert_assist/priv/licenses/texts/Apache-2.0.txt` | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` |
| `LicenseRef-IANA-TZDB` | `LicenseRef-IANA-TZDB` | `apps/allbert_assist/priv/licenses/texts/LicenseRef-IANA-TZDB.txt` | `9fabb75b7f899b6dc8c49cd6189cc23829ae0bcd872783485cf602bbaeb03986` |
| `LicenseRef-SQLite-Public-Domain` | `LicenseRef-SQLite-Public-Domain` | `apps/allbert_assist/priv/licenses/texts/LicenseRef-SQLite-Public-Domain.txt` | `9de1b8e57a12e7120dce7ddd9263dd291ecd1c8a1eac1e03c33b18a660466280` |
| `LicenseText-03e8f968360fd51fc91e` | `MIT` | `apps/allbert_assist_web/assets/node_modules/y-indexeddb/LICENSE` | `03e8f968360fd51fc91e383f472bdd10c47321ba868cb72749d1f7a5fd89ec05` |
| `LicenseText-0cec06e0e55fbc3dc5ce` | `Apache-2.0` | `deps/telemetry/LICENSE` | `0cec06e0e55fbc3dc5cee4fca9b607f66cb8f4e4dbcf3b3c013594dd156732e9` |
| `LicenseText-0d542e0c8804e39aa7f3` | `Apache-2.0` | `deps/nimble_options/LICENSE.md` | `0d542e0c8804e39aa7f37eb00da5a762149dc682d7829451287e11b938e94594` |
| `LicenseText-17e0c0a5f23abbea243e` | `ISC` | `deps/fsmx/LICENSE` | `17e0c0a5f23abbea243eefd0803ab49df18894bec1f78547c0000408c0511e77` |
| `LicenseText-210da78eba582c0dff0a` | `MIT` | `deps/swoosh/LICENSE.txt` | `210da78eba582c0dff0a31f3b61d375578671f5193f5d50be16e58989127c214` |
| `LicenseText-26f042d624e62b760e70` | `MIT` | `deps/websock/LICENSE` | `26f042d624e62b760e707842347e9e08cb981491d3cecfdd63bc48fc32e870e3` |
| `LicenseText-2c3c57158df2131ff09f` | `MIT` | `deps/finch/LICENSE.md` | `2c3c57158df2131ff09f57d9c7850da0844910f0fa8ac60294dd9396e3672e81` |
| `LicenseText-2c5a81b6b6636c9cb4d0` | `MIT` | `deps/thousand_island/LICENSE` | `2c5a81b6b6636c9cb4d022c4891091a1267a42be6e5005190f29951db6cc1bb6` |
| `LicenseText-341baa53605ed85d6f95` | `MIT` | `apps/allbert_assist_web/assets/node_modules/yjs/LICENSE` | `341baa53605ed85d6f95782322854cca56c655ebc7fd4712649b8e7afc6020ff` |
| `LicenseText-3f3399039f88edcfac16` | `MIT` | `apps/allbert_assist/priv/licenses/upstream/yaml-elixir-2.12.2-MIT.txt` | `3f3399039f88edcfac16c1c194dc76595aa5b891d2d1e2cf4d357281fd55378a` |
| `LicenseText-3f3d46a6af1e58f4808e` | `MIT` | `deps/bandit/LICENSE` | `3f3d46a6af1e58f4808e66b0a61aeb8befd2b3a03736404bead69758551353cb` |
| `LicenseText-41a686069f0199ff369d` | `MIT` | `deps/phoenix/LICENSE.md` | `41a686069f0199ff369d7e5277d5267385cc54d9199f1efc960bacbe2e799255` |
| `LicenseText-44558f34d16d29b67340` | `MIT` | `deps/multigraph/LICENSE` | `44558f34d16d29b67340bbd8e0d14c46415a6203b36e83c566be60ef8ff77b98` |
| `LicenseText-4c9fb97c01f065d3113d` | `Apache-2.0` | `deps/jsv/LICENSE` | `4c9fb97c01f065d3113df961e895744276238f69361905181e383503cad57283` |
| `LicenseText-4fa3fe63742b9f9fe89e` | `BSD-3-Clause` | `deps/erlexec/LICENSE` | `4fa3fe63742b9f9fe89e4fe7e4ec52f3775c8cb78480ca455e57b9d64b04976f` |
| `LicenseText-5446db1e43fe52faf3fa` | `MIT` | `apps/allbert_assist_web/assets/node_modules/lib0/LICENSE` | `5446db1e43fe52faf3faab7e9959fe3762ac11bdc61c0945934c498affd52d73` |
| `LicenseText-5843e5f79c0efe4e91ba` | `MIT` | `deps/peri/LICENSE` | `5843e5f79c0efe4e91ba580781f61aa66aab1ab18a8e4be48726d0940917d71e` |
| `LicenseText-592f189ada3d2ebd5056` | `MIT` | `deps/dns_cluster/LICENSE.md` | `592f189ada3d2ebd5056776aac97a04e9a928c2e6ddf373b5eafa1724b630d88` |
| `LicenseText-5a76ffa3373ac1fbc8c8` | `MIT` | `deps/phoenix_live_view/LICENSE.md` | `5a76ffa3373ac1fbc8c8645967b980896154c26113c827d3c01c4b0158c057c6` |
| `LicenseText-5ef76176b7be1574f800` | `Apache-2.0` | `deps/jido/LICENSE` | `5ef76176b7be1574f8006b1060a94f01518fc133ea1fb3136819d0fa7b473c8f` |
| `LicenseText-60e0b68c0f35c078eef3` | `MIT` | `apps/allbert_assist/priv/licenses/upstream/tailwind-labs-MIT.txt` | `60e0b68c0f35c078eef3a5d29419d0b03ff84ec1df9c3f9d6e39a519a5ae7985` |
| `LicenseText-634c31233e0435bea4f4` | `MIT` | `deps/phoenix_live_dashboard/LICENSE.md` | `634c31233e0435bea4f449a20a72617d95c11ec74ab97860d6a1bb1467937f31` |
| `LicenseText-688f69bf70e9e9a49b9d` | `MIT` | `apps/allbert_assist/priv/licenses/upstream/topbar-3.0.0-MIT.txt` | `688f69bf70e9e9a49b9db688ee6f2727ff1bf57e9f1e7136835063886afed2e0` |
| `LicenseText-6c73f07b2f5abbb4fd00` | `Apache-2.0` | `deps/jason/LICENSE` | `6c73f07b2f5abbb4fd00f30cba97e4f358b86977b46ad82d87357964a2d350e0` |
| `LicenseText-72a55ac957f96e79263e` | `MIT` | `deps/ecto_sqlite3/LICENSE` | `72a55ac957f96e79263e435f4a646822cf4406e63bb53a235b21abbc2e79303a` |
| `LicenseText-77fcbbf2f545f77ecbb0` | `MIT` | `deps/server_sent_events/LICENSE.md` | `77fcbbf2f545f77ecbb043641c7f8d9c0c39de3936d2d7d6da14f46a7ccddd67` |
| `LicenseText-79bfd5cbf8cb79a2c73d` | `Apache-2.0` | `deps/mime/LICENSE` | `79bfd5cbf8cb79a2c73d1d94447461f93407c7f14dc789942c2ee41e167ba48f` |
| `LicenseText-8709e3ac65c84637c422` | `MIT` | `apps/allbert_assist/priv/licenses/upstream/daisyUI-5.0.35-MIT.txt` | `8709e3ac65c84637c422dc8082b893d9997fce093751c77b2f1983bf29dbf9ea` |
| `LicenseText-87cff0c8b7a957427363` | `BSD-2-Clause` | `deps/gen_smtp/LICENSE` | `87cff0c8b7a957427363e36976e31606459d136d7908d6b398ecdadaf5f93965` |
| `LicenseText-8f57c966fcad8d3aadf0` | `MIT` | `deps/fuse/LICENSE` | `8f57c966fcad8d3aadf0e2c488984c030b7be76eb81af1a5c8d34c8b4c3be88c` |
| `LicenseText-928a3c3144938459f365` | `ISC` | `deps/ranch/LICENSE` | `928a3c3144938459f365c53759e58d366f88ba370ec8806df354bd8c832d9855` |
| `LicenseText-95f5c9410a95332b0833` | `MIT` | `deps/idna/LICENSE` | `95f5c9410a95332b0833c4606028ee00008cd8c497336e230df3144d1a720bda` |
| `LicenseText-9b138284c9d79dd1afc6` | `Apache-2.0` | `deps/toml/LICENSE` | `9b138284c9d79dd1afc613fbf4b5d4fcbd3da4512aedec39f33c1fb7b4c7396c` |
| `LicenseText-a6cba85bc92e0cff7a45` | `Apache-2.0` | `deps/decimal/LICENSE.txt` | `a6cba85bc92e0cff7a450b1d873c0eaa2e9fc96bf472df0247a26bec77bf3ff9` |
| `LicenseText-aa30b438110fe4596156` | `MIT` | `deps/crontab/LICENSE` | `aa30b438110fe45961567d99ff9d9ea93759eeb49791e3cfdc63c6d24a6b0b46` |
| `LicenseText-af7e0c1deb1e000cd1c0` | `ISC` | `deps/poolboy/LICENSE` | `af7e0c1deb1e000cd1c0aa389d3b404ba5a05fe30df83e9e041c41ca408c33d2` |
| `LicenseText-b25c71a74ae1e2961b15` | `Apache-2.0` | `deps/plug/LICENSE` | `b25c71a74ae1e2961b15c611ee26d9b3bd171d0833e407867a3debd9d1de3759` |
| `LicenseText-bcf95e9988ff9289107d` | `MIT` | `deps/time_zone_info/LICENSE.md` | `bcf95e9988ff9289107d00a279c7cd3fbeee6f18d26d814e9e2d4a045ad1a5c0` |
| `LicenseText-c553be3b8179832aa738` | `Apache-2.0` | `deps/expo/LICENSE` | `c553be3b8179832aa738b0fa04c2e1a53f520da13fcf7b6c2f6e9cf4468c41ad` |
| `LicenseText-c71d239df91726fc519c` | `Apache-2.0` | `deps/owl/LICENSE.txt` | `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4` |
| `LicenseText-ca32dea0238d9df54d9d` | `MIT` | `apps/allbert_assist/priv/licenses/upstream/splode-0.3.1-MIT.txt` | `ca32dea0238d9df54d9d8f66d96c2461ba3c2edb1e560244d6da5700232b00a2` |
| `LicenseText-d27edf5fdec47e5820c5` | `MIT` | `deps/ymlr/LICENSE` | `d27edf5fdec47e5820c55b908886fa6417376e2bceaa17e01dba93dbbdea17bd` |
| `LicenseText-d61102ef42e7fb35fc5b` | `MIT` | `deps/websockex/LICENSE` | `d61102ef42e7fb35fc5b18b609f9d92ceff4eb9b4e58cb682a1ebf81164389bc` |
| `LicenseText-dcaf5543c243163a31bf` | `MIT` | `deps/phoenix_ecto/LICENSE` | `dcaf5543c243163a31bfcdb83d6a6fe0b1393f4229eb0855c0105aace586bffe` |
| `LicenseText-dd6488c9c1a4ce2dc978` | `MIT` | `apps/allbert_assist_web/assets/node_modules/isomorphic.js/LICENSE` | `dd6488c9c1a4ce2dc978ecee067e5b6a725b52e6057a450b24f1a23bc373b057` |
| `LicenseText-ddca79cf0c4ae18d20a5` | `BSD-2-Clause` | `deps/yamerl/LICENSE` | `ddca79cf0c4ae18d20a568ee48dfb0789390d48e9268d82e8500fdd1167e2afe` |
| `LicenseText-deb19f64e750f0151e06` | `MIT` | `deps/hermes_mcp/LICENSE` | `deb19f64e750f0151e065f384cc587b73909c70ea91a863a762e2f5b92691e50` |
| `LicenseText-f415e7921fee4b575319` | `MIT` | `deps/abnf_parsec/LICENSE` | `f415e7921fee4b5753193f80482cb0ebb36faac94955993368818ef67067e404` |
| `LicenseText-f5692d451cbfe2a04e37` | `MIT` | `deps/phoenix_html/LICENSE` | `f5692d451cbfe2a04e3721e99ffbe88d1e9a09f1ff2fc1115de700d7e7abdbe4` |
| `LicenseText-f797420dcf4959e5760d` | `Apache-2.0` | `deps/plug_crypto/LICENSE` | `f797420dcf4959e5760d7ae4c20d66345fa3cd9d04cf03309d6911020e8049b7` |
| `LicenseText-f9e693078c728b5e6285` | `Apache-2.0` | `deps/req/LICENSE.md` | `f9e693078c728b5e62856ba365d6d4e915c87dc47228bfc607132e7f7505101f` |
| `LicenseText-fcf06aacb36ee2923711` | `BSD-3-Clause` | `apps/allbert_assist_web/assets/node_modules/js-base64/LICENSE.md` | `fcf06aacb36ee29237110d6b3a9fbd6296e85ad4324263abf5f8a5cfb5706c81` |
| `MPL-2.0` | `MPL-2.0` | `apps/allbert_assist/priv/licenses/texts/MPL-2.0.txt` | `f35b870c59c69f29f127265bb7adb7417c6fe0d19a75c2dd8a50fd8447e66536` |

## Known Components

### `beam-abnf-parsec` — abnf_parsec

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-f415e7921fee4b575319`
- Application: `abnf_parsec`
- Provenance: `{"ecosystem":"hex","license_source":"deps/abnf_parsec/LICENSE","package":"abnf_parsec","url":"https://hex.pm/packages/abnf_parsec"}`

### `beam-allbert-assist` — allbert_assist

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `allbert_assist`
- Provenance: `{"ecosystem":"allbert","repository":"https://github.com/lexlapax/allbert-assist"}`

### `beam-allbert-assist-web` — allbert_assist_web

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `allbert_assist_web`
- Provenance: `{"ecosystem":"allbert","repository":"https://github.com/lexlapax/allbert-assist"}`

### `beam-bandit` — bandit

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-3f3d46a6af1e58f4808e`
- Application: `bandit`
- Provenance: `{"ecosystem":"hex","license_source":"deps/bandit/LICENSE","package":"bandit","url":"https://hex.pm/packages/bandit"}`

### `beam-castore` — castore

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `castore`
- Provenance: `{"ecosystem":"hex","package":"castore","url":"https://hex.pm/packages/castore"}`

### `beam-crontab` — crontab

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-aa30b438110fe4596156`
- Application: `crontab`
- Provenance: `{"ecosystem":"hex","license_source":"deps/crontab/LICENSE","package":"crontab","url":"https://hex.pm/packages/crontab"}`

### `beam-db-connection` — db_connection

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `db_connection`
- Provenance: `{"ecosystem":"hex","package":"db_connection","url":"https://hex.pm/packages/db_connection"}`

### `beam-decimal` — decimal

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-a6cba85bc92e0cff7a45`
- Application: `decimal`
- Provenance: `{"ecosystem":"hex","license_source":"deps/decimal/LICENSE.txt","package":"decimal","url":"https://hex.pm/packages/decimal"}`

### `beam-dns-cluster` — dns_cluster

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-592f189ada3d2ebd5056`
- Application: `dns_cluster`
- Provenance: `{"ecosystem":"hex","license_source":"deps/dns_cluster/LICENSE.md","package":"dns_cluster","url":"https://hex.pm/packages/dns_cluster"}`

### `beam-dotenvy` — dotenvy

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-a6cba85bc92e0cff7a45`
- Application: `dotenvy`
- Provenance: `{"ecosystem":"hex","license_source":"deps/dotenvy/LICENSE","package":"dotenvy","url":"https://hex.pm/packages/dotenvy"}`

### `beam-ecto` — ecto

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `ecto`
- Provenance: `{"ecosystem":"hex","package":"ecto","url":"https://hex.pm/packages/ecto"}`

### `beam-ecto-sql` — ecto_sql

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `ecto_sql`
- Provenance: `{"ecosystem":"hex","package":"ecto_sql","url":"https://hex.pm/packages/ecto_sql"}`

### `beam-ecto-sqlite3` — ecto_sqlite3

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-72a55ac957f96e79263e`
- Application: `ecto_sqlite3`
- Provenance: `{"ecosystem":"hex","license_source":"deps/ecto_sqlite3/LICENSE","package":"ecto_sqlite3","url":"https://hex.pm/packages/ecto_sqlite3"}`

### `beam-erlexec` — erlexec

- Kind: `beam_app`
- License expression: `BSD-3-Clause`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-4fa3fe63742b9f9fe89e`
- Application: `erlexec`
- Provenance: `{"ecosystem":"hex","license_source":"deps/erlexec/LICENSE","package":"erlexec","url":"https://hex.pm/packages/erlexec"}`

### `beam-expo` — expo

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-c553be3b8179832aa738`
- Application: `expo`
- Provenance: `{"ecosystem":"hex","license_source":"deps/expo/LICENSE","package":"expo","url":"https://hex.pm/packages/expo"}`

### `beam-exqlite` — exqlite

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-72a55ac957f96e79263e`
- Application: `exqlite`
- Provenance: `{"ecosystem":"hex","license_source":"deps/exqlite/LICENSE","package":"exqlite","url":"https://hex.pm/packages/exqlite"}`

### `beam-finch` — finch

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-2c3c57158df2131ff09f`
- Application: `finch`
- Provenance: `{"ecosystem":"hex","license_source":"deps/finch/LICENSE.md","package":"finch","url":"https://hex.pm/packages/finch"}`

### `beam-fsmx` — fsmx

- Kind: `beam_app`
- License expression: `ISC`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-17e0c0a5f23abbea243e`
- Application: `fsmx`
- Provenance: `{"ecosystem":"hex","license_source":"deps/fsmx/LICENSE","package":"fsmx","url":"https://hex.pm/packages/fsmx"}`

### `beam-fuse` — fuse

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-8f57c966fcad8d3aadf0`
- Application: `fuse`
- Provenance: `{"ecosystem":"hex","license_source":"deps/fuse/LICENSE","package":"fuse","url":"https://hex.pm/packages/fuse"}`

### `beam-gen-smtp` — gen_smtp

- Kind: `beam_app`
- License expression: `BSD-2-Clause`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-87cff0c8b7a957427363`
- Application: `gen_smtp`
- Provenance: `{"ecosystem":"hex","license_source":"deps/gen_smtp/LICENSE","package":"gen_smtp","url":"https://hex.pm/packages/gen_smtp"}`

### `beam-gettext` — gettext

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `gettext`
- Provenance: `{"ecosystem":"hex","package":"gettext","url":"https://hex.pm/packages/gettext"}`

### `beam-hermes-mcp` — hermes_mcp

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-deb19f64e750f0151e06`
- Application: `hermes_mcp`
- Provenance: `{"ecosystem":"hex","license_source":"deps/hermes_mcp/LICENSE","package":"hermes_mcp","url":"https://hex.pm/packages/hermes_mcp"}`

### `beam-hpax` — hpax

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-a6cba85bc92e0cff7a45`
- Application: `hpax`
- Provenance: `{"ecosystem":"hex","license_source":"deps/hpax/LICENSE.txt","package":"hpax","url":"https://hex.pm/packages/hpax"}`

### `beam-idna` — idna

- Kind: `beam_app`
- License expression: `MIT AND Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-95f5c9410a95332b0833`, `Apache-2.0`
- Application: `idna`
- Provenance: `{"ecosystem":"hex","license_source":"deps/idna/LICENSE","package":"idna","url":"https://hex.pm/packages/idna"}`

### `beam-jason` — jason

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-6c73f07b2f5abbb4fd00`
- Application: `jason`
- Provenance: `{"ecosystem":"hex","license_source":"deps/jason/LICENSE","package":"jason","url":"https://hex.pm/packages/jason"}`

### `beam-jido` — jido

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-5ef76176b7be1574f800`
- Application: `jido`
- Provenance: `{"ecosystem":"hex","license_source":"deps/jido/LICENSE","package":"jido","url":"https://hex.pm/packages/jido"}`

### `beam-jido-action` — jido_action

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-5ef76176b7be1574f800`
- Application: `jido_action`
- Provenance: `{"ecosystem":"hex","license_source":"deps/jido_action/LICENSE","package":"jido_action","url":"https://hex.pm/packages/jido_action"}`

### `beam-jido-ai` — jido_ai

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-5ef76176b7be1574f800`
- Application: `jido_ai`
- Provenance: `{"ecosystem":"hex","license_source":"deps/jido_ai/LICENSE.md","package":"jido_ai","url":"https://hex.pm/packages/jido_ai"}`

### `beam-jido-signal` — jido_signal

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-5ef76176b7be1574f800`
- Application: `jido_signal`
- Provenance: `{"ecosystem":"hex","license_source":"deps/jido_signal/LICENSE","package":"jido_signal","url":"https://hex.pm/packages/jido_signal"}`

### `beam-jsv` — jsv

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-4c9fb97c01f065d3113d`
- Application: `jsv`
- Provenance: `{"ecosystem":"hex","license_source":"deps/jsv/LICENSE","package":"jsv","url":"https://hex.pm/packages/jsv"}`

### `beam-llm-db` — llm_db

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-5ef76176b7be1574f800`
- Application: `llm_db`
- Provenance: `{"ecosystem":"hex","license_source":"deps/llm_db/LICENSE","package":"llm_db","url":"https://hex.pm/packages/llm_db"}`

### `beam-mime` — mime

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-79bfd5cbf8cb79a2c73d`
- Application: `mime`
- Provenance: `{"ecosystem":"hex","license_source":"deps/mime/LICENSE","package":"mime","url":"https://hex.pm/packages/mime"}`

### `beam-mint` — mint

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-a6cba85bc92e0cff7a45`
- Application: `mint`
- Provenance: `{"ecosystem":"hex","license_source":"deps/mint/LICENSE.txt","package":"mint","url":"https://hex.pm/packages/mint"}`

### `beam-multigraph` — multigraph

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-44558f34d16d29b67340`
- Application: `multigraph`
- Provenance: `{"ecosystem":"hex","license_source":"deps/multigraph/LICENSE","package":"multigraph","url":"https://hex.pm/packages/multigraph"}`

### `beam-muontrap` — muontrap

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `muontrap`
- Provenance: `{"ecosystem":"hex","package":"muontrap","url":"https://hex.pm/packages/muontrap"}`

### `beam-nimble-options` — nimble_options

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-0d542e0c8804e39aa7f3`
- Application: `nimble_options`
- Provenance: `{"ecosystem":"hex","license_source":"deps/nimble_options/LICENSE.md","package":"nimble_options","url":"https://hex.pm/packages/nimble_options"}`

### `beam-nimble-parsec` — nimble_parsec

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `nimble_parsec`
- Provenance: `{"ecosystem":"hex","package":"nimble_parsec","url":"https://hex.pm/packages/nimble_parsec"}`

### `beam-nimble-pool` — nimble_pool

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `nimble_pool`
- Provenance: `{"ecosystem":"hex","package":"nimble_pool","url":"https://hex.pm/packages/nimble_pool"}`

### `beam-owl` — owl

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-c71d239df91726fc519c`
- Application: `owl`
- Provenance: `{"ecosystem":"hex","license_source":"deps/owl/LICENSE.txt","package":"owl","url":"https://hex.pm/packages/owl"}`

### `beam-peri` — peri

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-5843e5f79c0efe4e91ba`
- Application: `peri`
- Provenance: `{"ecosystem":"hex","license_source":"deps/peri/LICENSE","package":"peri","url":"https://hex.pm/packages/peri"}`

### `beam-phoenix` — phoenix

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-41a686069f0199ff369d`
- Application: `phoenix`
- Provenance: `{"ecosystem":"hex","license_source":"deps/phoenix/LICENSE.md","package":"phoenix","url":"https://hex.pm/packages/phoenix"}`

### `beam-phoenix-ecto` — phoenix_ecto

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-dcaf5543c243163a31bf`
- Application: `phoenix_ecto`
- Provenance: `{"ecosystem":"hex","license_source":"deps/phoenix_ecto/LICENSE","package":"phoenix_ecto","url":"https://hex.pm/packages/phoenix_ecto"}`

### `beam-phoenix-html` — phoenix_html

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-f5692d451cbfe2a04e37`
- Application: `phoenix_html`
- Provenance: `{"ecosystem":"hex","license_source":"deps/phoenix_html/LICENSE","package":"phoenix_html","url":"https://hex.pm/packages/phoenix_html"}`

### `beam-phoenix-live-dashboard` — phoenix_live_dashboard

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-634c31233e0435bea4f4`
- Application: `phoenix_live_dashboard`
- Provenance: `{"ecosystem":"hex","license_source":"deps/phoenix_live_dashboard/LICENSE.md","package":"phoenix_live_dashboard","url":"https://hex.pm/packages/phoenix_live_dashboard"}`

### `beam-phoenix-live-view` — phoenix_live_view

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-5a76ffa3373ac1fbc8c8`
- Application: `phoenix_live_view`
- Provenance: `{"ecosystem":"hex","license_source":"deps/phoenix_live_view/LICENSE.md","package":"phoenix_live_view","url":"https://hex.pm/packages/phoenix_live_view"}`

### `beam-phoenix-pubsub` — phoenix_pubsub

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-41a686069f0199ff369d`
- Application: `phoenix_pubsub`
- Provenance: `{"ecosystem":"hex","license_source":"deps/phoenix_pubsub/LICENSE.md","package":"phoenix_pubsub","url":"https://hex.pm/packages/phoenix_pubsub"}`

### `beam-phoenix-template` — phoenix_template

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-41a686069f0199ff369d`
- Application: `phoenix_template`
- Provenance: `{"ecosystem":"hex","license_source":"deps/phoenix_template/LICENSE.md","package":"phoenix_template","url":"https://hex.pm/packages/phoenix_template"}`

### `beam-plug` — plug

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-b25c71a74ae1e2961b15`
- Application: `plug`
- Provenance: `{"ecosystem":"hex","license_source":"deps/plug/LICENSE","package":"plug","url":"https://hex.pm/packages/plug"}`

### `beam-plug-crypto` — plug_crypto

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-f797420dcf4959e5760d`
- Application: `plug_crypto`
- Provenance: `{"ecosystem":"hex","license_source":"deps/plug_crypto/LICENSE","package":"plug_crypto","url":"https://hex.pm/packages/plug_crypto"}`

### `beam-poolboy` — poolboy

- Kind: `beam_app`
- License expression: `ISC`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-af7e0c1deb1e000cd1c0`
- Application: `poolboy`
- Provenance: `{"ecosystem":"hex","license_source":"deps/poolboy/LICENSE","package":"poolboy","url":"https://hex.pm/packages/poolboy"}`

### `beam-ranch` — ranch

- Kind: `beam_app`
- License expression: `ISC`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-928a3c3144938459f365`
- Application: `ranch`
- Provenance: `{"ecosystem":"hex","license_source":"deps/ranch/LICENSE","package":"ranch","url":"https://hex.pm/packages/ranch"}`

### `beam-req` — req

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-f9e693078c728b5e6285`
- Application: `req`
- Provenance: `{"ecosystem":"hex","license_source":"deps/req/LICENSE.md","package":"req","url":"https://hex.pm/packages/req"}`

### `beam-req-llm` — req_llm

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-5ef76176b7be1574f800`
- Application: `req_llm`
- Provenance: `{"ecosystem":"hex","license_source":"deps/req_llm/LICENSE","package":"req_llm","url":"https://hex.pm/packages/req_llm"}`

### `beam-server-sent-events` — server_sent_events

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-77fcbbf2f545f77ecbb0`
- Application: `server_sent_events`
- Provenance: `{"ecosystem":"hex","license_source":"deps/server_sent_events/LICENSE.md","package":"server_sent_events","url":"https://hex.pm/packages/server_sent_events"}`

### `beam-splode` — splode

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-ca32dea0238d9df54d9d`
- Application: `splode`
- Provenance: `{"ecosystem":"hex","license_source":"apps/allbert_assist/priv/licenses/upstream/splode-0.3.1-MIT.txt","package":"splode","url":"https://hex.pm/packages/splode"}`

### `beam-swoosh` — swoosh

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-210da78eba582c0dff0a`
- Application: `swoosh`
- Provenance: `{"ecosystem":"hex","license_source":"deps/swoosh/LICENSE.txt","package":"swoosh","url":"https://hex.pm/packages/swoosh"}`

### `beam-telemetry` — telemetry

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-0cec06e0e55fbc3dc5ce`
- Application: `telemetry`
- Provenance: `{"ecosystem":"hex","license_source":"deps/telemetry/LICENSE","package":"telemetry","url":"https://hex.pm/packages/telemetry"}`

### `beam-telemetry-metrics` — telemetry_metrics

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-0cec06e0e55fbc3dc5ce`
- Application: `telemetry_metrics`
- Provenance: `{"ecosystem":"hex","license_source":"deps/telemetry_metrics/LICENSE","package":"telemetry_metrics","url":"https://hex.pm/packages/telemetry_metrics"}`

### `beam-telemetry-poller` — telemetry_poller

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-0cec06e0e55fbc3dc5ce`
- Application: `telemetry_poller`
- Provenance: `{"ecosystem":"hex","license_source":"deps/telemetry_poller/LICENSE","package":"telemetry_poller","url":"https://hex.pm/packages/telemetry_poller"}`

### `beam-texture` — texture

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-4c9fb97c01f065d3113d`
- Application: `texture`
- Provenance: `{"ecosystem":"hex","license_source":"deps/texture/LICENSE","package":"texture","url":"https://hex.pm/packages/texture"}`

### `beam-thousand-island` — thousand_island

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-2c5a81b6b6636c9cb4d0`
- Application: `thousand_island`
- Provenance: `{"ecosystem":"hex","license_source":"deps/thousand_island/LICENSE","package":"thousand_island","url":"https://hex.pm/packages/thousand_island"}`

### `beam-time-zone-info` — time_zone_info

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-bcf95e9988ff9289107d`
- Application: `time_zone_info`
- Provenance: `{"ecosystem":"hex","license_source":"deps/time_zone_info/LICENSE.md","package":"time_zone_info","url":"https://hex.pm/packages/time_zone_info"}`

### `beam-toml` — toml

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-9b138284c9d79dd1afc6`
- Application: `toml`
- Provenance: `{"ecosystem":"hex","license_source":"deps/toml/LICENSE","package":"toml","url":"https://hex.pm/packages/toml"}`

### `beam-unicode-util-compat` — unicode_util_compat

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-0d542e0c8804e39aa7f3`
- Application: `unicode_util_compat`
- Provenance: `{"ecosystem":"hex","license_source":"deps/unicode_util_compat/LICENSE","package":"unicode_util_compat","url":"https://hex.pm/packages/unicode_util_compat"}`

### `beam-websock` — websock

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-26f042d624e62b760e70`
- Application: `websock`
- Provenance: `{"ecosystem":"hex","license_source":"deps/websock/LICENSE","package":"websock","url":"https://hex.pm/packages/websock"}`

### `beam-websock-adapter` — websock_adapter

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-26f042d624e62b760e70`
- Application: `websock_adapter`
- Provenance: `{"ecosystem":"hex","license_source":"deps/websock_adapter/LICENSE","package":"websock_adapter","url":"https://hex.pm/packages/websock_adapter"}`

### `beam-websockex` — websockex

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-d61102ef42e7fb35fc5b`
- Application: `websockex`
- Provenance: `{"ecosystem":"hex","license_source":"deps/websockex/LICENSE","package":"websockex","url":"https://hex.pm/packages/websockex"}`

### `beam-yamerl` — yamerl

- Kind: `beam_app`
- License expression: `BSD-2-Clause`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-ddca79cf0c4ae18d20a5`
- Application: `yamerl`
- Provenance: `{"ecosystem":"hex","license_source":"deps/yamerl/LICENSE","package":"yamerl","url":"https://hex.pm/packages/yamerl"}`

### `beam-yaml-elixir` — yaml_elixir

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-3f3399039f88edcfac16`
- Application: `yaml_elixir`
- Provenance: `{"ecosystem":"hex","license_source":"apps/allbert_assist/priv/licenses/upstream/yaml-elixir-2.12.2-MIT.txt","package":"yaml_elixir","url":"https://hex.pm/packages/yaml_elixir"}`

### `beam-ymlr` — ymlr

- Kind: `beam_app`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-d27edf5fdec47e5820c5`
- Application: `ymlr`
- Provenance: `{"ecosystem":"hex","license_source":"deps/ymlr/LICENSE","package":"ymlr","url":"https://hex.pm/packages/ymlr"}`

### `beam-zoi` — zoi

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `zoi`
- Provenance: `{"ecosystem":"hex","package":"zoi","url":"https://hex.pm/packages/zoi"}`

### `castore-mozilla-ca` — Castore Mozilla CA certificate bundle

- Kind: `managed_file`
- License expression: `MPL-2.0`
- Disposition: bundled when selected for the target
- Required texts: `MPL-2.0`
- Managed application: `castore`
- Managed relative path: `priv/cacerts.pem`
- Provenance: `{"castore_commit":"d7c27ff79eb627ee08a978c09d0e7f45dd410bc5","castore_version":"1.0.20","scope":"Only lib/castore-*/priv/cacerts.pem; Castore code remains Apache-2.0"}`
- Source availability: `{"converter":{"immutable_url":"https://raw.githubusercontent.com/curl/curl/84c5dcdb05202d3260b4631c2fa842123f87b362/scripts/mk-ca-bundle.pl","name":"curl mk-ca-bundle.pl","sha256":"0d232e570f9b7fb2daba1499299af277cf8c01b7d3f36c79f6d7fa32030a60fa","version":"1.33"},"immutable_url":"https://raw.githubusercontent.com/mozilla-firefox/firefox/4acf6f0d6ccb0f7008080e0d91b15258c4c6686c/security/nss/lib/ckfw/builtins/certdata.txt","sha256":"e57912808daef7b2b0fa4df2ccf17e47aeaf26c839a38f85c76003ebafd866bd"}`

### `dispatcher` — Allbert release dispatcher

- Kind: `managed_file`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Managed path: `bin/allbert`
- Provenance: `{"ecosystem":"allbert"}`

### `external-chromium` — Chromium/Chrome browser

- Kind: `external`
- License expression: `NOASSERTION`
- Disposition: external / not bundled
- Required texts: none (external declaration)
- Forbidden bundled paths: `["plugins/allbert.browser/priv/playwright_bridge/.local-browsers","plugins/allbert.browser/priv/playwright_bridge/node_modules/playwright-core/.local-browsers"]`
- Provenance: `{"disposition":"host-managed external runtime; inventory only if artifact policy changes"}`

### `external-node` — Node.js runtime

- Kind: `external`
- License expression: `NOASSERTION`
- Disposition: external / not bundled
- Required texts: none (external declaration)
- Forbidden bundled paths: `["bin/node","plugins/allbert.browser/priv/playwright_bridge/node"]`
- Provenance: `{"disposition":"host-managed external runtime; inventory only if artifact policy changes"}`

### `external-playwright` — Playwright runtime

- Kind: `external`
- License expression: `NOASSERTION`
- Disposition: external / not bundled
- Required texts: none (external declaration)
- Forbidden bundled paths: `["plugins/allbert.browser/priv/playwright_bridge/node_modules/playwright","plugins/allbert.browser/priv/playwright_bridge/node_modules/playwright-core"]`
- Provenance: `{"disposition":"host-managed external runtime; inventory only if artifact policy changes"}`

### `external-tradingagents-python` — TradingAgents/Python runtime

- Kind: `external`
- License expression: `NOASSERTION`
- Disposition: external / not bundled
- Required texts: none (external declaration)
- Forbidden bundled paths: `["python","venv","plugins/stocksage/venv","plugins/stocksage/.venv"]`
- Provenance: `{"disposition":"host-managed external runtime; inventory only if artifact policy changes"}`

### `iana-tzdb-data` — IANA Time Zone Database compiled data

- Kind: `managed_file`
- License expression: `LicenseRef-IANA-TZDB`
- Disposition: bundled when selected for the target
- Required texts: `LicenseRef-IANA-TZDB`
- Managed application: `time_zone_info`
- Managed relative path: `priv/data.etf`
- Provenance: `{"observed_source_component":"time_zone_info 0.7.15","review_note":"The compiled data payload contains tz database data, not the three separately BSD-licensed tzdb source-code files.","upstream":"https://data.iana.org/time-zones/tzdb/"}`

### `openssl-macos` — OpenSSL library copied into macOS ERTS

- Kind: `managed_file`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Managed application: `crypto`
- Managed relative path: `priv/lib/libcrypto.3.dylib`
- Targets: `["macos-arm64"]`
- Provenance: `{"reason":"conditional macOS ERTS closure","upstream":"https://openssl-library.org/"}`

### `otp-asn1` — Erlang/OTP asn1

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `asn1`
- Provenance: `{"ecosystem":"otp","project":"Erlang/OTP"}`

### `otp-compiler` — Erlang/OTP compiler

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `compiler`
- Provenance: `{"ecosystem":"otp","project":"Erlang/OTP"}`

### `otp-crypto` — Erlang/OTP crypto

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `crypto`
- Provenance: `{"ecosystem":"otp","project":"Erlang/OTP"}`

### `otp-eex` — Erlang/OTP eex

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `eex`
- Provenance: `{"ecosystem":"otp","project":"Erlang/OTP"}`

### `otp-elixir` — Erlang/OTP elixir

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `elixir`
- Provenance: `{"ecosystem":"otp","project":"Erlang/OTP"}`

### `otp-iex` — Erlang/OTP iex

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `iex`
- Provenance: `{"ecosystem":"otp","project":"Erlang/OTP"}`

### `otp-kernel` — Erlang/OTP kernel

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `kernel`
- Provenance: `{"ecosystem":"otp","project":"Erlang/OTP"}`

### `otp-logger` — Erlang/OTP logger

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `logger`
- Provenance: `{"ecosystem":"otp","project":"Erlang/OTP"}`

### `otp-mnesia` — Erlang/OTP mnesia

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `mnesia`
- Provenance: `{"ecosystem":"otp","project":"Erlang/OTP"}`

### `otp-public_key` — Erlang/OTP public_key

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `public_key`
- Provenance: `{"ecosystem":"otp","project":"Erlang/OTP"}`

### `otp-runtime_tools` — Erlang/OTP runtime_tools

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `runtime_tools`
- Provenance: `{"ecosystem":"otp","project":"Erlang/OTP"}`

### `otp-sasl` — Erlang/OTP sasl

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `sasl`
- Provenance: `{"ecosystem":"otp","project":"Erlang/OTP"}`

### `otp-ssl` — Erlang/OTP ssl

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `ssl`
- Provenance: `{"ecosystem":"otp","project":"Erlang/OTP"}`

### `otp-stdlib` — Erlang/OTP stdlib

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `stdlib`
- Provenance: `{"ecosystem":"otp","project":"Erlang/OTP"}`

### `otp-xmerl` — Erlang/OTP xmerl

- Kind: `beam_app`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Application: `xmerl`
- Provenance: `{"ecosystem":"otp","project":"Erlang/OTP"}`

### `playwright-bridge-helper` — Allbert Playwright bridge helper (without Playwright runtime)

- Kind: `managed_file`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Managed path: `plugins/allbert.browser/priv/playwright_bridge/bridge.js`
- Provenance: `{"boundary":"node_modules and browser binaries are forbidden","ecosystem":"allbert"}`

### `plugin-allbert-artifacts` — allbert.artifacts staged plugin

- Kind: `managed_file`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Managed path: `plugins/allbert.artifacts/allbert_plugin.json`
- Provenance: `{"ecosystem":"allbert","repository":"https://github.com/lexlapax/allbert-assist"}`

### `plugin-allbert-browser` — allbert.browser staged plugin

- Kind: `managed_file`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Managed path: `plugins/allbert.browser/allbert_plugin.json`
- Provenance: `{"ecosystem":"allbert","repository":"https://github.com/lexlapax/allbert-assist"}`

### `plugin-allbert-discord` — allbert.discord staged plugin

- Kind: `managed_file`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Managed path: `plugins/allbert.discord/allbert_plugin.json`
- Provenance: `{"ecosystem":"allbert","repository":"https://github.com/lexlapax/allbert-assist"}`

### `plugin-allbert-email` — allbert.email staged plugin

- Kind: `managed_file`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Managed path: `plugins/allbert.email/allbert_plugin.json`
- Provenance: `{"ecosystem":"allbert","repository":"https://github.com/lexlapax/allbert-assist"}`

### `plugin-allbert-matrix` — allbert.matrix staged plugin

- Kind: `managed_file`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Managed path: `plugins/allbert.matrix/allbert_plugin.json`
- Provenance: `{"ecosystem":"allbert","repository":"https://github.com/lexlapax/allbert-assist"}`

### `plugin-allbert-notes_files` — allbert.notes_files staged plugin

- Kind: `managed_file`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Managed path: `plugins/allbert.notes_files/allbert_plugin.json`
- Provenance: `{"ecosystem":"allbert","repository":"https://github.com/lexlapax/allbert-assist"}`

### `plugin-allbert-research` — allbert.research staged plugin

- Kind: `managed_file`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Managed path: `plugins/allbert.research/allbert_plugin.json`
- Provenance: `{"ecosystem":"allbert","repository":"https://github.com/lexlapax/allbert-assist"}`

### `plugin-allbert-signal` — allbert.signal staged plugin

- Kind: `managed_file`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Managed path: `plugins/allbert.signal/allbert_plugin.json`
- Provenance: `{"ecosystem":"allbert","repository":"https://github.com/lexlapax/allbert-assist"}`

### `plugin-allbert-slack` — allbert.slack staged plugin

- Kind: `managed_file`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Managed path: `plugins/allbert.slack/allbert_plugin.json`
- Provenance: `{"ecosystem":"allbert","repository":"https://github.com/lexlapax/allbert-assist"}`

### `plugin-allbert-telegram` — allbert.telegram staged plugin

- Kind: `managed_file`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Managed path: `plugins/allbert.telegram/allbert_plugin.json`
- Provenance: `{"ecosystem":"allbert","repository":"https://github.com/lexlapax/allbert-assist"}`

### `plugin-allbert-tui` — allbert.tui staged plugin

- Kind: `managed_file`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Managed path: `plugins/allbert.tui/allbert_plugin.json`
- Provenance: `{"ecosystem":"allbert","repository":"https://github.com/lexlapax/allbert-assist"}`

### `plugin-allbert-whatsapp` — allbert.whatsapp staged plugin

- Kind: `managed_file`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Managed path: `plugins/allbert.whatsapp/allbert_plugin.json`
- Provenance: `{"ecosystem":"allbert","repository":"https://github.com/lexlapax/allbert-assist"}`

### `plugin-stocksage` — stocksage staged plugin

- Kind: `managed_file`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Managed path: `plugins/stocksage/allbert_plugin.json`
- Provenance: `{"ecosystem":"allbert","repository":"https://github.com/lexlapax/allbert-assist"}`

### `release-launcher` — Mix release launcher

- Kind: `managed_file`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Managed path: `bin/allbert-release`
- Provenance: `{"project":"Elixir Mix.Release"}`

### `runtime-erts` — Erlang Runtime System (ERTS)

- Kind: `managed_file`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Managed path: `erts-17.0.1/bin/beam.smp`
- Provenance: `{"project":"Erlang/OTP","url":"https://github.com/erlang/otp"}`

### `sqlite-exqlite-nif` — Exqlite native library with SQLite amalgamation

- Kind: `managed_file`
- License expression: `MIT AND LicenseRef-SQLite-Public-Domain`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-72a55ac957f96e79263e`, `LicenseRef-SQLite-Public-Domain`
- Managed application: `exqlite`
- Managed relative path: `priv/sqlite3_nif.so`
- Provenance: `{"sqlite":"https://www.sqlite.org/","upstream":"https://github.com/elixir-sqlite/exqlite"}`

### `web-daisyui` — daisyUI

- Kind: `managed_file`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-8709e3ac65c84637c422`
- Managed application: `allbert_assist_web`
- Managed relative path: `priv/static/cache_manifest.json`
- Provenance: `{"license_source":"apps/allbert_assist/priv/licenses/upstream/daisyUI-5.0.35-MIT.txt","scope":"compiled into the reviewed Phoenix static asset set","url":"https://github.com/saadeghi/daisyui"}`

### `web-first-party` — Allbert compiled web assets

- Kind: `managed_file`
- License expression: `Apache-2.0`
- Disposition: bundled when selected for the target
- Required texts: `Apache-2.0`
- Managed application: `allbert_assist_web`
- Managed relative path: `priv/static/cache_manifest.json`
- Provenance: `{"scope":"compiled into the reviewed Phoenix static asset set","url":"https://github.com/lexlapax/allbert-assist"}`

### `web-heroicons` — Heroicons 2.2.0

- Kind: `managed_file`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-60e0b68c0f35c078eef3`
- Managed application: `allbert_assist_web`
- Managed relative path: `priv/static/cache_manifest.json`
- Provenance: `{"license_source":"apps/allbert_assist/priv/licenses/upstream/tailwind-labs-MIT.txt","license_source_url":"https://raw.githubusercontent.com/tailwindlabs/heroicons/0435d4ca364a608cc75e2f8683d374e55abbae26/LICENSE","scope":"compiled into the reviewed Phoenix static asset set","url":"https://github.com/tailwindlabs/heroicons"}`

### `web-isomorphic-js` — isomorphic.js 0.2.5

- Kind: `managed_file`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-dd6488c9c1a4ce2dc978`
- Managed application: `allbert_assist_web`
- Managed relative path: `priv/static/cache_manifest.json`
- Provenance: `{"license_source":"apps/allbert_assist_web/assets/node_modules/isomorphic.js/LICENSE","scope":"compiled into the reviewed Phoenix static asset set","url":"https://www.npmjs.com/package/isomorphic.js"}`

### `web-js-base64` — js-base64 3.7.8

- Kind: `managed_file`
- License expression: `BSD-3-Clause`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-fcf06aacb36ee2923711`
- Managed application: `allbert_assist_web`
- Managed relative path: `priv/static/cache_manifest.json`
- Provenance: `{"license_source":"apps/allbert_assist_web/assets/node_modules/js-base64/LICENSE.md","scope":"compiled into the reviewed Phoenix static asset set","url":"https://github.com/dankogai/js-base64"}`

### `web-lib0` — lib0 0.2.117

- Kind: `managed_file`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-5446db1e43fe52faf3fa`
- Managed application: `allbert_assist_web`
- Managed relative path: `priv/static/cache_manifest.json`
- Provenance: `{"license_source":"apps/allbert_assist_web/assets/node_modules/lib0/LICENSE","scope":"compiled into the reviewed Phoenix static asset set","url":"https://github.com/dmonad/lib0"}`

### `web-tailwindcss` — Tailwind CSS 4.1.12

- Kind: `managed_file`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-60e0b68c0f35c078eef3`
- Managed application: `allbert_assist_web`
- Managed relative path: `priv/static/cache_manifest.json`
- Provenance: `{"license_source":"apps/allbert_assist/priv/licenses/upstream/tailwind-labs-MIT.txt","license_source_url":"https://raw.githubusercontent.com/tailwindlabs/tailwindcss/6791e8133c3cf496727d1e7c55e3a35bfffc0e69/LICENSE","scope":"compiled into the reviewed Phoenix static asset set","tag_commit":"6791e8133c3cf496727d1e7c55e3a35bfffc0e69","url":"https://github.com/tailwindlabs/tailwindcss"}`

### `web-topbar` — topbar 3.0.0

- Kind: `managed_file`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-688f69bf70e9e9a49b9d`
- Managed application: `allbert_assist_web`
- Managed relative path: `priv/static/cache_manifest.json`
- Provenance: `{"license_source":"apps/allbert_assist/priv/licenses/upstream/topbar-3.0.0-MIT.txt","scope":"compiled into the reviewed Phoenix static asset set","url":"https://github.com/buunguyen/topbar"}`

### `web-y-indexeddb` — y-indexeddb 9.0.12

- Kind: `managed_file`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-03e8f968360fd51fc91e`
- Managed application: `allbert_assist_web`
- Managed relative path: `priv/static/cache_manifest.json`
- Provenance: `{"license_source":"apps/allbert_assist_web/assets/node_modules/y-indexeddb/LICENSE","scope":"compiled into the reviewed Phoenix static asset set","url":"https://github.com/yjs/y-indexeddb"}`

### `web-yjs` — Yjs 13.6.30

- Kind: `managed_file`
- License expression: `MIT`
- Disposition: bundled when selected for the target
- Required texts: `LicenseText-341baa53605ed85d6f95`
- Managed application: `allbert_assist_web`
- Managed relative path: `priv/static/cache_manifest.json`
- Provenance: `{"license_source":"apps/allbert_assist_web/assets/node_modules/yjs/LICENSE","scope":"compiled into the reviewed Phoenix static asset set","url":"https://github.com/yjs/yjs"}`
