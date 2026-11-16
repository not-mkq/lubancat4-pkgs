// SPDX-License-Identifier: GPL-2.0
/*
 * EmbedFire EBF410173 - 7 inch 1024x600 DSI panel sold for the LubanCat-4.
 *
 * There is no driver for this panel upstream, and the vendor tree does not have one
 * either: the BSP drives it with its own panel-simple, which takes the whole power-on
 * command list from the device tree through "panel-init-sequence" and
 * "panel-exit-sequence". Those two properties exist nowhere in mainline (grep
 * drivers/gpu/drm/panel/ and Documentation/devicetree/bindings/display/panel/), which is
 * why the overlay is dead there. So what is being ported is not a driver but those
 * bytes: they move from the device tree into driver data, which is how mainline carries
 * init sequences for e.g. panel-boe-himax8279d.c and panel-ilitek-ili9806e-dsi.c.
 *
 * Every value is transcribed from
 *   kernel-lbc-develop-6.1/arch/arm64/boot/dts/rockchip/overlay/
 *     rk3588s-lubancat-4-dsi0-vp2-1024x600-7inch-ebf410173-overlay.dts
 * EmbedFire never names the controller chip, so the driver is named after the panel's
 * product code and the seven commands below stay raw.
 *
 * The BSP stores commands as
 *   struct { u8 data_type; u8 delay_ms; u8 payload_length; u8 payload[]; }
 * (panel_simple_parse_cmd_seq() / panel_cmd_header in the BSP's panel-simple.c), where
 * payload includes the DCS command byte and data_type 0x15 / 0x05 are
 * MIPI_DSI_DCS_SHORT_WRITE_PARAM / MIPI_DSI_DCS_SHORT_WRITE. Decoded, the vendor list is:
 *   15 00 02 80 AC   0x80, one parameter 0xAC, no delay
 *   ...              0x81 0xB8, 0x82 0x09, 0x83 0x78, 0x84 0x7F, 0x85 0xBB, 0x86 0x70
 *   05 C8 01 11      Sleep Out, then 200 ms
 *   05 C8 01 29      Display On,  then 200 ms
 * and the exit list is 05 78 01 28 -> Display Off with 120 ms, followed by
 * 05 00 01 10 -> Sleep In with 120 ms.
 */

#include <linux/delay.h>
#include <linux/err.h>
#include <linux/gpio/consumer.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/regulator/consumer.h>

#include <drm/drm_mipi_dsi.h>
#include <drm/drm_modes.h>
#include <drm/drm_panel.h>

#include <video/mipi_display.h>

struct ebf410173_cmd {
	u8 cmd;
	const u8 *params;
	size_t nparams;
	unsigned int delay_ms;
};

/* One DCS command with a single parameter, followed by a delay in ms. */
#define EBF_CMD_P(c, p, d) { .cmd = (c), .params = (const u8[]){ p }, .nparams = 1, \
			     .delay_ms = (d) }
/* One DCS command without parameters. */
#define EBF_CMD(c, d) { .cmd = (c), .nparams = 0, .delay_ms = (d) }

static const struct ebf410173_cmd ebf410173_power_on[] = {
	EBF_CMD_P(0x80, 0xac, 0),
	EBF_CMD_P(0x81, 0xb8, 0),
	EBF_CMD_P(0x82, 0x09, 0),
	EBF_CMD_P(0x83, 0x78, 0),
	EBF_CMD_P(0x84, 0x7f, 0),
	EBF_CMD_P(0x85, 0xbb, 0),
	EBF_CMD_P(0x86, 0x70, 0),
	EBF_CMD(MIPI_DCS_EXIT_SLEEP_MODE, 200),
	EBF_CMD(MIPI_DCS_SET_DISPLAY_ON, 200),
};

/*
 * Vendor panel-exit-sequence is [05 78 01 28 / 05 00 01 10]: Display Off with a 120 ms
 * wait, then Sleep In. Both are DCS commands with no parameters.
 */
static const struct ebf410173_cmd ebf410173_power_off[] = {
	EBF_CMD(MIPI_DCS_SET_DISPLAY_OFF, 120),
	EBF_CMD(MIPI_DCS_ENTER_SLEEP_MODE, 120),
};

struct ebf410173 {
	struct drm_panel base;
	struct mipi_dsi_device *dsi;
	struct regulator *power;
	struct gpio_desc *reset;
};

static struct ebf410173 *to_ebf410173(struct drm_panel *panel)
{
	return container_of(panel, struct ebf410173, base);
}

/*
 * The panel is 1024x600 at 51.668640 MHz: (1024+160+10+160) x (600+12+1+23) gives
 * 1354 x 636 -> 51.64 MHz at ~60 Hz, which matches the vendor's
 * "clock = <51668640>" once that number is read in Hz. Porch values and both sync
 * polarities come straight from the vendor's display-timings block.
 *
 * The vendor also sets de-active = <1> and pixelclk-active = <0>. A DRM display mode has
 * no flag for DE or pixel clock edge (only hsync/vsync), and a DSI panel transfers
 * pixels with its own embedded sync, so those two have nothing to be mapped onto.
 *
 * width/height: the vendor wrote "size,width" and "size,height" (133 x 74), which are
 * not the binding's width-mm/height-mm, so the BSP never read them either. These two
 * only feed the connector's physical size for aspect-ratio hints.
 */
static const struct drm_display_mode ebf410173_mode = {
	.clock = 51669,
	.hdisplay = 1024,
	.hsync_start = 1024 + 160,
	.hsync_end = 1024 + 160 + 10,
	.htotal = 1024 + 160 + 10 + 160,
	.vdisplay = 600,
	.vsync_start = 600 + 12,
	.vsync_end = 600 + 12 + 1,
	.vtotal = 600 + 12 + 1 + 23,
	.width_mm = 154,
	.height_mm = 90,
	.flags = DRM_MODE_FLAG_NHSYNC | DRM_MODE_FLAG_NVSYNC,
};

static int ebf410173_write_cmds(struct mipi_dsi_device *dsi,
				const struct ebf410173_cmd *seq, size_t n)
{
	const struct ebf410173_cmd *c;
	int ret;
	size_t i;

	for (i = 0; i < n; i++) {
		c = &seq[i];
		ret = mipi_dsi_dcs_write(dsi, c->cmd, c->params, c->nparams);
		if (ret < 0)
			return dev_err_probe(&dsi->dev, ret,
					     "failed to write command 0x%02x\n", c->cmd);
		if (c->delay_ms)
			msleep(c->delay_ms);
	}

	return 0;
}

static int ebf410173_prepare(struct drm_panel *panel)
{
	struct ebf410173 *ctx = to_ebf410173(panel);
	struct mipi_dsi_device *dsi = ctx->dsi;
	int ret;

	ret = regulator_enable(ctx->power);
	if (ret < 0)
		return dev_err_probe(&dsi->dev, ret, "failed to enable power\n");

	/*
	 * The vendor overlay carries reset-delay-ms = <0> and init-delay-ms = <20>, and
	 * its panel-simple drives reset high (asserted, GPIO_ACTIVE_LOW) and low again
	 * with nothing in between, i.e. a zero length pulse. A 20 ms pulse costs nothing
	 * and is what every other DSI panel driver here does, so this is a deliberate
	 * deviation: assert, 20 ms, release, 20 ms, then the command list.
	 */
	gpiod_set_value_cansleep(ctx->reset, 1);
	msleep(20);
	gpiod_set_value_cansleep(ctx->reset, 0);
	msleep(20);

	ret = ebf410173_write_cmds(dsi, ebf410173_power_on,
				   ARRAY_SIZE(ebf410173_power_on));
	if (ret < 0) {
		gpiod_set_value_cansleep(ctx->reset, 1);
		regulator_disable(ctx->power);
		return ret;
	}

	return 0;
}

static int ebf410173_enable(struct drm_panel *panel)
{
	/* enable-delay-ms = <35> in the vendor overlay; Display On is in the list. */
	msleep(35);

	return 0;
}

static int ebf410173_disable(struct drm_panel *panel)
{
	struct ebf410173 *ctx = to_ebf410173(panel);

	return ebf410173_write_cmds(ctx->dsi, ebf410173_power_off,
				    ARRAY_SIZE(ebf410173_power_off));
}

static int ebf410173_unprepare(struct drm_panel *panel)
{
	struct ebf410173 *ctx = to_ebf410173(panel);

	gpiod_set_value_cansleep(ctx->reset, 1);

	return regulator_disable(ctx->power);
}

static int ebf410173_get_modes(struct drm_panel *panel,
			       struct drm_connector *connector)
{
	/* No ctx here on purpose: the mode is a constant of this driver, nothing about this
	 * panel instance is needed to describe it. A local that is fetched and not used is how
	 * a warning (and, under W=1 or a future -Werror, a build failure) gets shipped. */
	struct drm_display_mode *mode;

	mode = drm_mode_duplicate(connector->dev, &ebf410173_mode);
	if (!mode)
		return 0;

	drm_mode_set_name(mode);
	mode->type = DRM_MODE_TYPE_DRIVER | DRM_MODE_TYPE_PREFERRED;

	connector->display_info.width_mm = mode->width_mm;
	connector->display_info.height_mm = mode->height_mm;
	connector->display_info.bus_flags = 0;

	drm_mode_probed_add(connector, mode);

	return 1;
}

static const struct drm_panel_funcs ebf410173_panel_funcs = {
	.disable = ebf410173_disable,
	.unprepare = ebf410173_unprepare,
	.prepare = ebf410173_prepare,
	.enable = ebf410173_enable,
	.get_modes = ebf410173_get_modes,
};

static int ebf410173_probe(struct mipi_dsi_device *dsi)
{
	struct device *dev = &dsi->dev;
	struct ebf410173 *ctx;
	int ret;

	ctx = devm_drm_panel_alloc(dev, __typeof(*ctx), base, &ebf410173_panel_funcs,
				   DRM_MODE_CONNECTOR_DSI);
	if (IS_ERR(ctx))
		return PTR_ERR(ctx);

	ctx->dsi = dsi;
	mipi_dsi_set_drvdata(dsi, ctx);

	/*
	 * dsi,lanes = <4>, dsi,format = <MIPI_DSI_FMT_RGB888> and dsi,flags =
	 * (MIPI_DSI_MODE_VIDEO | MIPI_DSI_MODE_VIDEO_BURST | MIPI_DSI_MODE_LPM |
	 * MIPI_DSI_MODE_NO_EOT_PACKET) all come from the vendor's dsi1 description of
	 * this panel (rk3588s-lubancat-4-dsi1-vp3-1024x600-7inch-ebf410173.dtsi).
	 *
	 * MIPI_DSI_MODE_VIDEO is not cosmetic. RK3588 drives dsi1 through the Synopsys
	 * dw-mipi-dsi2 bridge (drivers/gpu/drm/bridge/synopsys/dw-mipi-dsi2.c), and
	 * that driver picks the link's operating mode from this very bit:
	 *
	 *	if (dsi2->mode_flags & MIPI_DSI_MODE_VIDEO)
	 *		dw_mipi_dsi2_set_vid_mode(dsi2);
	 *	else
	 *		dw_mipi_dsi2_set_data_stream_mode(dsi2);
	 *
	 * and dw_mipi_dsi2_video_mode_cfg() returns early, without programming
	 * hactive/hsa/hbp/hline, when the bit is clear. Without it the link runs as a
	 * raw data stream, no video packets reach the panel, and the only things that
	 * still work are the DCS control packets (page writes, Sleep Out, Display On)
	 * and the panel's own backlight - which is exactly "backlight on, nothing
	 * displayed" while /sys/class/drm/card1-DSI-1/modes still reads 1024x600.
	 * MIPI_DSI_MODE_VIDEO_BURST is read too (the RK glue multiplies the lane rate
	 * by 10/9 for burst, and the bridge programs the burst type).
	 *
	 * This corrects an earlier version of this comment, which claimed the Rockchip
	 * host driver never reads mode_flags. That was read off dw-mipi-dsi-rockchip.c,
	 * the driver for the *other* DSI controller; fde30000 binds with
	 * dw_mipi_dsi2_rockchip_ops.
	 *
	 * The dsi0 wiring of this panel (the rk3588s-lubancat4-dsi0-*.dtso overlays)
	 * shares this driver. The vendor's dsi0 and dsi1 files spell dsi,flags the same
	 * way (VIDEO | VIDEO_BURST | LPM | NO_EOT_PACKET), so one flag set in this
	 * driver covers both wirings.
	 */
	dsi->lanes = 4;
	dsi->format = MIPI_DSI_FMT_RGB888;
	dsi->mode_flags = MIPI_DSI_MODE_VIDEO |
			  MIPI_DSI_MODE_VIDEO_BURST |
			  MIPI_DSI_MODE_LPM |
			  MIPI_DSI_MODE_NO_EOT_PACKET;

	ctx->power = devm_regulator_get(dev, "power");
	if (IS_ERR(ctx->power))
		return dev_err_probe(dev, PTR_ERR(ctx->power), "failed to get power\n");

	/* Absent is legal: the pin may be wired to a fixed rail on some revisions. */
	ctx->reset = devm_gpiod_get_optional(dev, "reset", GPIOD_OUT_LOW);
	if (IS_ERR(ctx->reset))
		return dev_err_probe(dev, PTR_ERR(ctx->reset), "failed to get reset\n");

	ret = drm_panel_of_backlight(&ctx->base);
	if (ret)
		return dev_err_probe(dev, ret, "failed to get backlight\n");

	ret = devm_drm_panel_add(dev, &ctx->base);
	if (ret < 0)
		return dev_err_probe(dev, ret, "failed to add panel\n");

	return devm_mipi_dsi_attach(dev, dsi);
}

static const struct of_device_id ebf410173_of_match[] = {
	{ .compatible = "embedfire,ebf410173" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, ebf410173_of_match);

static struct mipi_dsi_driver ebf410173_driver = {
	.driver = {
		.name = "panel-embedfire-ebf410173",
		.of_match_table = ebf410173_of_match,
	},
	.probe = ebf410173_probe,
};
module_mipi_dsi_driver(ebf410173_driver);

MODULE_DESCRIPTION("EmbedFire EBF410173 7 inch 1024x600 DSI panel");
MODULE_LICENSE("GPL v2");
