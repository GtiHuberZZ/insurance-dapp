# 航班延误险 DApp

基于 Scaffold-ETH 2 构建的去中心化航班延误保险应用。用户使用 USDC 购买航班延误险并获得保单 NFT；流动性提供者（LP）向保险资金池存入 USDC；Oracle 报告航班延误后，合约按保单条款自动处理赔付。保单 NFT 也可在二级市场转让。

> 本项目为开发与演示原型。`MockUSDC` 仅供本地测试，Oracle 报告依赖授权账户；上线前请完成安全审计并接入可信航班数据源。

## 功能

- **购买保险：** 用户支付保费，获得记录航班与承保信息的 ERC-721 保单 NFT。
- **提供流动性：** LP 存入 USDC 并获得资金池份额；资金池锁定有效保单所需准备金。
- **理赔与退款：** 授权 Oracle 报告延误，达到延误门槛时由资金池赔付；未出险保单到期后可处理退款。
- **保单转售：** 持有人可在二级市场挂单、撤单，买家以 USDC 购买。

## 技术栈

- Solidity `^0.8.20`、Hardhat、OpenZeppelin
- Scaffold-ETH 2、Next.js、React、TypeScript
- Wagmi、RainbowKit、Viem
- Yarn workspaces

## 项目架构

```text
packages/
├── hardhat/
│   ├── contracts/   # Solidity 智能合约
│   ├── deploy/      # 部署合约并初始化角色、Oracle
│   ├── scripts/     # 账户管理、ABI 生成和模拟脚本
│   └── test/        # Hardhat 测试
└── nextjs/
    ├── app/         # Next.js 页面
    ├── components/  # 前端组件
    ├── contracts/   # 合约 ABI 与部署地址
    └── hooks/       # Web3 与合约交互 hooks
```

业务调用关系：用户/LP → `Insurance` / `InsurancePool` → `PolicyNFT`；授权报告者 → `Oracle` → `Insurance` → `InsurancePool`；买卖双方 → `PolicyMarket` → USDC 与 `PolicyNFT`。

## 合约说明

| 合约 | 说明 |
| --- | --- |
| `MockUSDC.sol` | 本地测试用 USDC，精度为 6 位小数；任何人都可以 mint。请勿用于真实资产。 |
| `PolicyNFT.sol` | ERC-721 保单凭证，记录航班号、日期、保额、保费及保单状态。 |
| `InsurancePool.sol` | 管理 LP 存款与份额、保单资金准备金、理赔支付和到期退款。 |
| `Insurance.sol` | 主业务合约，负责购买保单、调用资金池和铸造 NFT，并处理理赔与退款。 |
| `Oracle.sol` | 接收具备 `REPORTER_ROLE` 的账户提交的延误报告，并转发至 `Insurance`。 |
| `PolicyMarket.sol` | 支持保单挂单、撤单和 USDC 购买，管理二级市场手续费。 |

## 环境要求

- Node.js `>=22.10.0`
- Yarn `4.13.0`（可使用 Corepack）

安装依赖：

```bash
corepack enable
yarn install
```

## 本地运行

在项目根目录打开 **3 个终端**，按以下顺序分别执行：

**终端 1：启动本地区块链**

```bash
yarn chain
```

**终端 2：部署合约**（等待终端 1 启动完成后执行）

```bash
yarn deploy
```

部署脚本会部署 MockUSDC、PolicyNFT、InsurancePool、Insurance、Oracle 和 PolicyMarket，并配置合约角色。默认本地网络为 Hardhat，链 ID 为 `31337`。

**终端 3：启动前端**（等待合约部署完成后执行）

```bash
yarn start
```

浏览器访问 <http://localhost:3000>，并将钱包连接至本地 Hardhat 网络。当前前端页面仍含 Scaffold-ETH 2 借贷示例界面；保险合约可通过 Debug Contracts 页面或脚本交互。

## 测试流程

编译合约：

```bash
yarn compile
```

运行 Hardhat 测试：

```bash
yarn test
```

建议测试购买与保单 NFT 铸造、LP 存取及准备金限制、达到延误门槛后的赔付、保单到期退款，以及市场挂单/撤单/购买等场景。**注意：当前 `packages/hardhat/test/Lending.ts` 仍是旧的 Corn/Lending 借贷示例测试，不覆盖本项目保险合约；保险流程的自动化测试需要补充。**


