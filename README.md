## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Deployments

Addresses below are taken from the latest `DemoDeploy.s.sol` broadcast runs.

### Base Mainnet (chain id `8453`)

| Contract | Address |
| --- | --- |
| IndexFactory | [`0x5D35e5F7253b2E885C6419ee58CD87b3BF1399E3`](https://basescan.org/address/0x5D35e5F7253b2E885C6419ee58CD87b3BF1399E3) |
| Index (implementation) | [`0xAC949e975caDeC0cb2332Ed2129D5e1Ed0d1Fa72`](https://basescan.org/address/0xAC949e975caDeC0cb2332Ed2129D5e1Ed0d1Fa72) |
| Index ("Demo index" / `DT`) | [`0x4B9F8F380BC68bb5dbEb21051933618A9Be4Db52`](https://basescan.org/address/0x4B9F8F380BC68bb5dbEb21051933618A9Be4Db52) |
| DriftwoodHook | [`0xB45f0258203b6f6cae49dC5036C2021C416540c0`](https://basescan.org/address/0xB45f0258203b6f6cae49dC5036C2021C416540c0) |
| Uniswap v4 PoolManager | [`0x498581fF718922c3f8e6A244956aF099B2652b2b`](https://basescan.org/address/0x498581fF718922c3f8e6A244956aF099B2652b2b) |
| WETH (mock, 18 dec) | [`0x23c406c6C67BEcDe62ca271e50f4c961917e4e2a`](https://basescan.org/address/0x23c406c6C67BEcDe62ca271e50f4c961917e4e2a) |
| USDT (mock, 6 dec) | [`0xB0B0f79d4ed33D44775fCd44523B423ff860Cd07`](https://basescan.org/address/0xB0B0f79d4ed33D44775fCd44523B423ff860Cd07) |
| ETH/USD feed (mock, $3000) | [`0x99Cc103CdFd914220996bd83eB6f0656Dd37Bd76`](https://basescan.org/address/0x99Cc103CdFd914220996bd83eB6f0656Dd37Bd76) |
| USDT/USD feed (mock, $1) | [`0xa71e5E19690EcEF1dEe62D9c20D8655Ff4d8DE90`](https://basescan.org/address/0xa71e5E19690EcEF1dEe62D9c20D8655Ff4d8DE90) |

### Base Sepolia (chain id `84532`)

| Contract | Address |
| --- | --- |
| IndexFactory | [`0xd26fb189c08543Cc0c94E239f2FDE4A6DA954D20`](https://sepolia.basescan.org/address/0xd26fb189c08543Cc0c94E239f2FDE4A6DA954D20) |
| Index (implementation) | [`0x31c628a15792331e1eC8aC3bBb5fBB56aD9cCA02`](https://sepolia.basescan.org/address/0x31c628a15792331e1eC8aC3bBb5fBB56aD9cCA02) |
| Index ("Demo index" / `DT`) | [`0xC167e9b0D5f5A8eAa3a6cfEf9A89d5CCCE3B3733`](https://sepolia.basescan.org/address/0xC167e9b0D5f5A8eAa3a6cfEf9A89d5CCCE3B3733) |
| DriftwoodHook | [`0x35d6e9057511e326c11Def4AFFaeD44947c980c0`](https://sepolia.basescan.org/address/0x35d6e9057511e326c11Def4AFFaeD44947c980c0) |
| Uniswap v4 PoolManager | [`0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`](https://sepolia.basescan.org/address/0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408) |
| WETH (mock, 18 dec) | [`0x430eaF6D6c8d75FFee6222E8FB9717857c92D133`](https://sepolia.basescan.org/address/0x430eaF6D6c8d75FFee6222E8FB9717857c92D133) |
| USDT (mock, 6 dec) | [`0xF3B10Cb6072e5881ACEcfA6F99EaE0f038207158`](https://sepolia.basescan.org/address/0xF3B10Cb6072e5881ACEcfA6F99EaE0f038207158) |
| ETH/USD feed (mock, $3000) | [`0x4dE1ff29aa4B83E77e73c6F865101a1227408a9E`](https://sepolia.basescan.org/address/0x4dE1ff29aa4B83E77e73c6F865101a1227408a9E) |
| USDT/USD feed (mock, $1) | [`0x1B190244841Ce63c260107e4783B64193e8D48A6`](https://sepolia.basescan.org/address/0x1B190244841Ce63c260107e4783B64193e8D48A6) |

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

**Demo deploy**

```shell
$ forge script script/DemoDeploy.s.sol:DemoDeployScript --rpc-url base-sepolia --broadcast --sig "run(address)" "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408" --slow --verify -vvvv --interactives 1
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
