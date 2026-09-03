// SPDX-License-Identifier: GPL-2.0-only
/* Minimal SM8150 SCC provider for Xiaomi nabu SSC QUPv3 SE2. */

#include <linux/bitops.h>
#include <linux/clk-provider.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/pm_runtime.h>
#include <linux/regmap.h>

#include <dt-bindings/clock/qcom,scc-sm8150-nabu.h>

#include "clk-branch.h"
#include "clk-rcg.h"
#include "common.h"
#include "scc-provider.h"

enum {
	P_BI_TCXO,
};

static const struct parent_map scc_parent_map[] = {
	{ P_BI_TCXO, 3 },
};

static const struct clk_parent_data scc_parent_data[] = {
	{ .fw_name = "bi_tcxo", .name = "bi_tcxo" },
};

static const struct freq_tbl ftbl_scc_cxo[] = {
	F(19200000, P_BI_TCXO, 1, 0, 0),
	{ }
};

static struct clk_rcg2 scc_main_rcg_clk_src = {
	.cmd_rcgr = 0x1000,
	.mnd_width = 0,
	.hid_width = 5,
	.parent_map = scc_parent_map,
	.freq_tbl = ftbl_scc_cxo,
	.clkr.hw.init = &(const struct clk_init_data) {
		.name = "scc_main_rcg_clk_src",
		.parent_data = scc_parent_data,
		.num_parents = ARRAY_SIZE(scc_parent_data),
		.ops = &clk_rcg2_ops,
	},
};

static struct clk_rcg2 scc_qupv3_se2_clk_src = {
	.cmd_rcgr = 0x4004,
	.mnd_width = 16,
	.hid_width = 5,
	.parent_map = scc_parent_map,
	.freq_tbl = ftbl_scc_cxo,
	.clkr.hw.init = &(const struct clk_init_data) {
		.name = "scc_qupv3_se2_clk_src",
		.parent_data = scc_parent_data,
		.num_parents = ARRAY_SIZE(scc_parent_data),
		.ops = &clk_rcg2_ops,
	},
};

/* Pair each wrapper-core vote with the downstream-only matching HCLK vote. */
static struct clk_branch scc_qupv3_core_m_hclk_clk = {
	.halt_reg = 0x9064,
	.halt_check = BRANCH_HALT_VOTED,
	.clkr = {
		.enable_reg = 0x21000,
		.enable_mask = BIT(11) | BIT(1),
		.hw.init = &(const struct clk_init_data) {
			.name = "scc_qupv3_core_m_hclk_clk",
			.parent_hws = (const struct clk_hw *[]) {
				&scc_main_rcg_clk_src.clkr.hw,
			},
			.num_parents = 1,
			.flags = CLK_SET_RATE_PARENT,
			.ops = &clk_branch2_ops,
		},
	},
};

static struct clk_branch scc_qupv3_2xcore_s_hclk_clk = {
	.halt_reg = 0x9060,
	.halt_check = BRANCH_HALT_VOTED,
	.clkr = {
		.enable_reg = 0x21000,
		.enable_mask = BIT(10) | BIT(0),
		.hw.init = &(const struct clk_init_data) {
			.name = "scc_qupv3_2xcore_s_hclk_clk",
			.parent_hws = (const struct clk_hw *[]) {
				&scc_main_rcg_clk_src.clkr.hw,
			},
			.num_parents = 1,
			.flags = CLK_SET_RATE_PARENT,
			.ops = &clk_branch2_ops,
		},
	},
};

static struct clk_branch scc_qupv3_se2_clk = {
	.halt_reg = 0x4130,
	.halt_check = BRANCH_HALT_VOTED,
	.clkr = {
		.enable_reg = 0x21000,
		.enable_mask = BIT(5),
		.hw.init = &(const struct clk_init_data) {
			.name = "scc_qupv3_se2_clk",
			.parent_hws = (const struct clk_hw *[]) {
				&scc_qupv3_se2_clk_src.clkr.hw,
			},
			.num_parents = 1,
			.flags = CLK_SET_RATE_PARENT,
			.ops = &clk_branch2_ops,
		},
	},
};

static struct clk_regmap *scc_sm8150_nabu_clocks[] = {
	[SCC_MAIN_RCG_CLK_SRC] = &scc_main_rcg_clk_src.clkr,
	[SCC_QUPV3_2XCORE_CLK] = &scc_qupv3_2xcore_s_hclk_clk.clkr,
	[SCC_QUPV3_CORE_CLK] = &scc_qupv3_core_m_hclk_clk.clkr,
	[SCC_QUPV3_SE2_CLK] = &scc_qupv3_se2_clk.clkr,
	[SCC_QUPV3_SE2_CLK_SRC] = &scc_qupv3_se2_clk_src.clkr,
};

static const struct regmap_config scc_sm8150_nabu_regmap_config = {
	.reg_bits = 32,
	.reg_stride = 4,
	.val_bits = 32,
	.max_register = 0x23000,
	.fast_io = true,
};

static const struct qcom_cc_desc scc_sm8150_nabu_desc = {
	.config = &scc_sm8150_nabu_regmap_config,
	.clks = scc_sm8150_nabu_clocks,
	.num_clks = ARRAY_SIZE(scc_sm8150_nabu_clocks),
};

/* Safe fallback: provider framework only, with no MMIO-backed clocks. */
static const struct qcom_cc_desc scc_sm8150_nabu_empty_desc = {
	.config = &scc_sm8150_nabu_regmap_config,
};

static int nabu_scc_provider_probe(struct platform_device *pdev)
{
	struct regmap *regmap;
	int ret;

	dev_notice(&pdev->dev,
		   "powered-empty-provider probe entered; no SCC MMIO access performed\n");

	ret = devm_pm_runtime_enable(&pdev->dev);
	if (ret)
		return dev_err_probe(&pdev->dev, ret,
				     "failed to enable SCC runtime PM\n");

	dev_notice(&pdev->dev, "resuming SCC LCX power domain\n");
	ret = pm_runtime_resume_and_get(&pdev->dev);
	if (ret)
		return dev_err_probe(&pdev->dev, ret,
				     "failed to resume SCC LCX power domain\n");

	dev_notice(&pdev->dev,
		   "SCC LCX power domain resumed; no SCC MMIO access performed\n");

	regmap = qcom_cc_map(pdev, &scc_sm8150_nabu_desc);
	if (IS_ERR(regmap)) {
		ret = PTR_ERR(regmap);
		dev_err_probe(&pdev->dev, ret,
			      "failed to map SCC register window\n");
		goto err_put;
	}

	dev_notice(&pdev->dev,
		   "mapped SCC register window; registering zero-clock provider\n");

	ret = qcom_cc_really_probe(&pdev->dev, &scc_sm8150_nabu_empty_desc,
				   regmap);
	if (ret) {
		dev_err_probe(&pdev->dev, ret,
			      "failed to register powered zero-clock SCC provider\n");
		goto err_put;
	}

	dev_notice(&pdev->dev,
		   "registered powered zero-clock SCC provider; clock hardware and MMIO access intentionally skipped\n");
	pm_runtime_put_sync(&pdev->dev);
	return 0;

err_put:
	pm_runtime_put_sync(&pdev->dev);
	return ret;
}

static const struct of_device_id nabu_scc_provider_match[] = {
	{ .compatible = "qcom,nabu-sm8150-scc" },
	{ }
};
MODULE_DEVICE_TABLE(of, nabu_scc_provider_match);

struct platform_driver nabu_scc_provider_driver = {
	.probe = nabu_scc_provider_probe,
	.driver = {
		.name = "nabu-sm8150-scc",
		.of_match_table = nabu_scc_provider_match,
	},
};
