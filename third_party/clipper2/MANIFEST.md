# Clipper2 source manifest

- Version: `2.0.1`
- Commit: `21ebba05db8894f0c7217ad35ea518080f324946`
- Source: <https://github.com/AngusJohnson/Clipper2/tree/Clipper2_2.0.1>
- License: Boost Software License 1.0 in [`LICENSE`](LICENSE)

Only the integer clipping and offset source files are compiled. The
triangulation header is present because the upstream aggregate header requires
it. The project does not compile or call the triangulation implementation.

| File | SHA-256 |
| --- | --- |
| `LICENSE` | `c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566` |
| `include/clipper2/clipper.core.h` | `91e7c1b418f59db4a8f30355e75f60e5d26adfd66c37578bcfd79f76ae8036ab` |
| `include/clipper2/clipper.engine.h` | `c3e8b7cabc80f5ab2592dd4401a8c445bd43422139ff216591aae94de1b5a175` |
| `include/clipper2/clipper.h` | `763c56acf64085af2b5081ca80466210507df3f49c53f9aaf3cce5597ed71e36` |
| `include/clipper2/clipper.minkowski.h` | `951b3f1d9b804f9fe9f1a142e6133c2efda2ba1c26c47e4c7de14c6d03a0eb39` |
| `include/clipper2/clipper.offset.h` | `00d0b670f40d030fad5cd658b71a34b8ff3185673825bbcc9f40e63d9216cbb2` |
| `include/clipper2/clipper.rectclip.h` | `279c6ae467cf9cec001c473d569dd7943a241690f5d64a17561efcb1a8e2e38e` |
| `include/clipper2/clipper.triangulation.h` | `a82d32e65583cce5a6d704796c54de3ddd2963d219057263a0f87f8d14a07d6c` |
| `include/clipper2/clipper.version.h` | `0d636f1599b09743496d5c15c7dcb5bc3101bd423d6745bf17e480edbffccdac` |
| `src/clipper.engine.cpp` | `4c66d5cd0c69a1d1caee2434a0099a9366771dcf186a8d987ab1b2d294872e98` |
| `src/clipper.offset.cpp` | `ebc01258953212d20fed090a4a740f94926c3c6706a092fec4c5e9cb5292305a` |
