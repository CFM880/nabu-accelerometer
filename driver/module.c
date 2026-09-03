// SPDX-License-Identifier: GPL-2.0-only

#include <linux/module.h>
#include <linux/platform_device.h>

#include "runtime-test.h"
#include "scc-provider.h"

static int __init nabu_sm8150_ssc_init(void)
{
	int ret;

	ret = platform_driver_register(&nabu_scc_provider_driver);
	if (ret)
		return ret;

	ret = platform_driver_register(&nabu_ssc_runtime_test_driver);
	if (ret)
		platform_driver_unregister(&nabu_scc_provider_driver);

	return ret;
}
module_init(nabu_sm8150_ssc_init);

static void __exit nabu_sm8150_ssc_exit(void)
{
	platform_driver_unregister(&nabu_ssc_runtime_test_driver);
	platform_driver_unregister(&nabu_scc_provider_driver);
}
module_exit(nabu_sm8150_ssc_exit);

MODULE_DESCRIPTION("Xiaomi nabu SM8150 SCC powered zero-clock provider diagnostic");
MODULE_LICENSE("GPL");
