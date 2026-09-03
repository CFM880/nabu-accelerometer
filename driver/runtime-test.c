// SPDX-License-Identifier: GPL-2.0-only
/* Enable SSC QUPv3 SE2 clocks without touching the serial-engine MMIO. */

#include <linux/clk.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>

#include "runtime-test.h"

struct nabu_ssc_runtime_test {
	struct clk_bulk_data clks[3];
};

static void nabu_ssc_runtime_disable(void *data)
{
	struct nabu_ssc_runtime_test *test = data;

	clk_bulk_disable_unprepare(ARRAY_SIZE(test->clks), test->clks);
}

static int nabu_ssc_runtime_test_probe(struct platform_device *pdev)
{
	static const char * const names[] = { "m-ahb", "s-ahb", "se" };
	struct nabu_ssc_runtime_test *test;
	int i, ret;

	test = devm_kzalloc(&pdev->dev, sizeof(*test), GFP_KERNEL);
	if (!test)
		return -ENOMEM;

	for (i = 0; i < ARRAY_SIZE(test->clks); i++)
		test->clks[i].id = names[i];

	ret = devm_clk_bulk_get(&pdev->dev, ARRAY_SIZE(test->clks), test->clks);
	if (ret)
		return dev_err_probe(&pdev->dev, ret, "failed to get SSC clocks\n");

	for (i = 0; i < ARRAY_SIZE(test->clks); i++) {
		ret = clk_set_rate(test->clks[i].clk, 19200000);
		if (ret)
			return dev_err_probe(&pdev->dev, ret,
					     "failed to set %s to 19.2 MHz\n",
					     names[i]);
	}

	ret = clk_bulk_prepare_enable(ARRAY_SIZE(test->clks), test->clks);
	if (ret)
		return dev_err_probe(&pdev->dev, ret,
				     "failed to enable SSC runtime clocks\n");

	ret = devm_add_action_or_reset(&pdev->dev, nabu_ssc_runtime_disable, test);
	if (ret)
		return ret;

	platform_set_drvdata(pdev, test);
	dev_info(&pdev->dev,
		 "SSC QUP SE2 clocks enabled; serial-engine MMIO intentionally untouched\n");
	return 0;
}

static const struct of_device_id nabu_ssc_runtime_test_match[] = {
	{ .compatible = "xiaomi,nabu-ssc-spi-runtime-test" },
	{ }
};
MODULE_DEVICE_TABLE(of, nabu_ssc_runtime_test_match);

struct platform_driver nabu_ssc_runtime_test_driver = {
	.probe = nabu_ssc_runtime_test_probe,
	.driver = {
		.name = "nabu-ssc-runtime-test",
		.of_match_table = nabu_ssc_runtime_test_match,
	},
};
