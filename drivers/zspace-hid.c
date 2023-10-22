/*  zspace-hid.c - subdriver to monitor ZSP USB/HID devices with NUT
 *
 *  Copyright (C)
 *  2003 - 2008 Arnaud Quette <arnaud.quette@free.fr>
 *  2005 - 2006 Peter Selinger <selinger@users.sourceforge.net>
 *
 *  Note: this subdriver was initially generated as a "stub" by the
 *  gen-usbhid-subdriver script. It must be customized.
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA
 *
 */

#include "main.h"     /* for getval() */
#include "nut_float.h"
#include "hidparser.h" /* for FindObject_with_ID_Node() */
#include "usbhid-ups.h"
#include "zspace-hid.h"
#include "usb-common.h"

#define ZSP_HID_VERSION      "Zspace HID 0.1"

/* Cyber Power Systems */
#define ZSP_VENDORID 0x36AA

/* Values for correcting the HID on some models
 * where LogMin and LogMax are set incorrectly in the HID.
 */
#define ZSP_VOLTAGE_LOGMIN 0
#define ZSP_VOLTAGE_LOGMAX 511 /* Includes safety margin. */

/*! Battery voltage scale factor.
 * For some devices, the reported battery voltage is off by factor
 * of 1.5 so we need to apply a scale factor to it to get the real
 * battery voltage. By default, the factor is 1 (no scaling).
 */
static double	battery_scale = 1;
static int	might_need_battery_scale = 0;
static int	battery_scale_checked = 0;

/*! If the ratio of the battery voltage to the nominal battery voltage exceeds
 * this factor, we assume that the battery voltage needs to be scaled by 2/3.
 */
static const double battery_voltage_sanity_check = 1.4;

static void *zsp_battery_scale(USBDevice_t *device)
{
	NUT_UNUSED_VARIABLE(device);

	might_need_battery_scale = 1;
	return NULL;
}

/* USB IDs device table */
static usb_device_id_t zsp_usb_device_table[] = {
	/* U2600 */
	{ USB_DEVICE(ZSP_VENDORID, 0x0101), &zsp_battery_scale },

	/* Terminating entry */
	{ 0, 0, NULL }
};

/*! Adjusts @a battery_scale if voltage is well above nominal.
 */
static void zsp_adjust_battery_scale(double batt_volt)
{
	const char *batt_volt_nom_str;
	double batt_volt_nom;

	if(battery_scale_checked) {
		return;
	}

	batt_volt_nom_str = dstate_getinfo("battery.voltage.nominal");
	if(!batt_volt_nom_str) {
		upsdebugx(2, "%s: 'battery.voltage.nominal' not available yet; skipping scale determination", __func__);
		return;
	}

	batt_volt_nom = strtod(batt_volt_nom_str, NULL);
	if(d_equal(batt_volt_nom, 0)) {
		upsdebugx(3, "%s: 'battery.voltage.nominal' is %s", __func__, batt_volt_nom_str);
		return;
	}

	if( (batt_volt / batt_volt_nom) > battery_voltage_sanity_check ) {
		upslogx(LOG_INFO, "%s: battery readings will be scaled by 2/3", __func__);
		battery_scale = 2.0/3;
	}

	battery_scale_checked = 1;
}

/* returns statically allocated string - must not use it again before
   done with result! */
static const char *zsp_battvolt_fun(double value)
{
	static char	buf[8];

	if(might_need_battery_scale) {
		zsp_adjust_battery_scale(value);
	}

	upsdebugx(5, "%s: battery_scale = %.3f", __func__, battery_scale);
	snprintf(buf, sizeof(buf), "%.1f", battery_scale * value);

	return buf;
}

static info_lkp_t zsp_battvolt[] = {
	{ 0, NULL, &zsp_battvolt_fun, NULL }
};

/* returns statically allocated string - must not use it again before
   done with result! */
static const char *zsp_battcharge_fun(double value)
{
	static char	buf[8];

	/* clamp battery charge to 100% */
	snprintf(buf, sizeof(buf), "%.0f", value < 100.0 ? value : 100.0);

	return buf;
}

static info_lkp_t zsp_battcharge[] = {
	{ 0, NULL, &zsp_battcharge_fun, NULL }
};

/* --------------------------------------------------------------- */
/*      Vendor-specific usage table */
/* --------------------------------------------------------------- */

/* ZSP usage table */
static usage_lkp_t zsp_usage_lkp[] = {
	{  NULL, 0x0 }
};

static usage_tables_t zsp_utab[] = {
	zsp_usage_lkp,
	hid_usage_lkp,
	NULL,
};

/* --------------------------------------------------------------- */
/* HID2NUT lookup table                                            */
/* --------------------------------------------------------------- */

static hid_info_t zsp_hid2nut[] = {
  /* { "unmapped.ups.powersummary.rechargeable", 0, 0, "UPS.PowerSummary.Rechargeable", NULL, "%.0f", 0, NULL }, */
  /* { "unmapped.ups.powersummary.capacitymode", 0, 0, "UPS.PowerSummary.CapacityMode", NULL, "%.0f", 0, NULL }, */
  /* { "unmapped.ups.powersummary.designcapacity", 0, 0, "UPS.PowerSummary.DesignCapacity", NULL, "%.0f", 0, NULL }, */
  /* { "unmapped.ups.powersummary.capacitygranularity1", 0, 0, "UPS.PowerSummary.CapacityGranularity1", NULL, "%.0f", 0, NULL }, */
  /* { "unmapped.ups.powersummary.capacitygranularity2", 0, 0, "UPS.PowerSummary.CapacityGranularity2", NULL, "%.0f", 0, NULL }, */
  /* { "unmapped.ups.powersummary.fullchargecapacity", 0, 0, "UPS.PowerSummary.FullChargeCapacity", NULL, "%.0f", 0, NULL }, */

  /* Battery page */
  { "battery.type", 0, 0, "UPS.PowerSummary.iDeviceChemistry", NULL, "%s", 0, stringid_conversion },
  { "battery.mfr.date", 0, 0, "UPS.PowerSummary.iOEMInformation", NULL, "%s", 0, stringid_conversion },
  { "battery.charge.warning", 0, 0, "UPS.PowerSummary.WarningCapacityLimit", NULL, "%.0f", 0, NULL },
  { "battery.charge.low", ST_FLAG_RW | ST_FLAG_STRING, 10, "UPS.PowerSummary.RemainingCapacityLimit", NULL, "%.0f", HU_FLAG_SEMI_STATIC, NULL },
  { "battery.charge", 0, 0, "UPS.PowerSummary.RemainingCapacity", NULL, "%s", 0, zsp_battcharge },
  { "battery.runtime", 0, 0, "UPS.PowerSummary.RunTimeToEmpty", NULL, "%.0f", 0, NULL },
  { "battery.runtime.low", ST_FLAG_RW | ST_FLAG_STRING, 10, "UPS.PowerSummary.RemainingTimeLimit", NULL, "%.0f", HU_FLAG_SEMI_STATIC, NULL },
  { "battery.voltage.nominal", 0, 0, "UPS.PowerSummary.ConfigVoltage", NULL, "%.0f", 0, NULL },
  { "battery.voltage", 0, 0, "UPS.PowerSummary.Voltage", NULL, "%s", 0, zsp_battvolt },

  /* UPS page */
  { "ups.load", 0, 0, "UPS.Output.PercentLoad", NULL, "%.0f", 0, NULL },
  { "ups.beeper.status", 0, 0, "UPS.PowerSummary.AudibleAlarmControl", NULL, "%s", 0, beeper_info },
  { "ups.test.result", 0, 0, "UPS.Output.Test", NULL, "%s", 0, test_read_info },
  { "ups.realpower.nominal", 0, 0, "UPS.Output.ConfigActivePower", NULL, "%.0f", 0, NULL },
  { "ups.delay.start", ST_FLAG_RW | ST_FLAG_STRING, 10, "UPS.Output.DelayBeforeStartup", NULL, DEFAULT_ONDELAY, HU_FLAG_ABSENT, NULL},
  { "ups.delay.shutdown", ST_FLAG_RW | ST_FLAG_STRING, 10, "UPS.Output.DelayBeforeShutdown", NULL, DEFAULT_OFFDELAY, HU_FLAG_ABSENT, NULL},
  { "ups.timer.start", 0, 0, "UPS.Output.DelayBeforeStartup", NULL, "%.0f", HU_FLAG_QUICK_POLL, NULL},
  { "ups.timer.shutdown", 0, 0, "UPS.Output.DelayBeforeShutdown", NULL, "%.0f", HU_FLAG_QUICK_POLL, NULL},
  { "ups.timer.reboot", 0, 0, "UPS.Output.DelayBeforeReboot", NULL, "%.0f", HU_FLAG_QUICK_POLL, NULL},

  /* Special case: ups.status & ups.alarm */
  { "BOOL", 0, 0, "UPS.PowerSummary.PresentStatus.ACPresent", NULL, NULL, HU_FLAG_QUICK_POLL, online_info },
  { "BOOL", 0, 0, "UPS.PowerSummary.PresentStatus.Charging", NULL, NULL, HU_FLAG_QUICK_POLL, charging_info },
  { "BOOL", 0, 0, "UPS.PowerSummary.PresentStatus.Discharging", NULL, NULL, HU_FLAG_QUICK_POLL, discharging_info },
  { "BOOL", 0, 0, "UPS.PowerSummary.PresentStatus.BelowRemainingCapacityLimit", NULL, NULL, HU_FLAG_QUICK_POLL, lowbatt_info },
  { "BOOL", 0, 0, "UPS.PowerSummary.PresentStatus.FullyCharged", NULL, NULL, 0, fullycharged_info },
  { "BOOL", 0, 0, "UPS.PowerSummary.PresentStatus.RemainingTimeLimitExpired", NULL, NULL, 0, timelimitexpired_info },
  { "BOOL", 0, 0, "UPS.Output.Boost", NULL, NULL, 0, boost_info },
  { "BOOL", 0, 0, "UPS.Output.Overload", NULL, NULL, 0, overload_info },

  /* Input page */
  { "input.frequency", 0, 0, "UPS.Input.Frequency", NULL, "%.1f", 0, NULL },
  { "input.voltage.nominal", 0, 0, "UPS.Input.ConfigVoltage", NULL, "%.0f", 0, NULL },
  { "input.voltage", 0, 0, "UPS.Input.Voltage", NULL, "%.1f", 0, NULL },
  { "input.transfer.low", ST_FLAG_RW | ST_FLAG_STRING, 10, "UPS.Input.LowVoltageTransfer", NULL, "%.0f", HU_FLAG_SEMI_STATIC, NULL },
  { "input.transfer.high", ST_FLAG_RW | ST_FLAG_STRING, 10, "UPS.Input.HighVoltageTransfer", NULL, "%.0f", HU_FLAG_SEMI_STATIC, NULL },

  /* Output page */
  { "output.frequency", 0, 0, "UPS.Output.Frequency", NULL, "%.1f", 0, NULL },
  { "output.voltage", 0, 0, "UPS.Output.Voltage", NULL, "%.1f", 0, NULL },
  { "output.voltage.nominal", 0, 0, "UPS.Output.ConfigVoltage", NULL, "%.0f", 0, NULL },

  /* instant commands. */
  { "test.battery.start.quick", 0, 0, "UPS.Output.Test", NULL, "1", HU_TYPE_CMD, NULL },
  { "test.battery.start.deep", 0, 0, "UPS.Output.Test", NULL, "2", HU_TYPE_CMD, NULL },
  { "test.battery.stop", 0, 0, "UPS.Output.Test", NULL, "3", HU_TYPE_CMD, NULL },
  { "load.off.delay", 0, 0, "UPS.Output.DelayBeforeShutdown", NULL, DEFAULT_OFFDELAY, HU_TYPE_CMD, NULL },
  { "load.on.delay", 0, 0, "UPS.Output.DelayBeforeStartup", NULL, DEFAULT_ONDELAY, HU_TYPE_CMD, NULL },
  { "shutdown.stop", 0, 0, "UPS.Output.DelayBeforeShutdown", NULL, "-1", HU_TYPE_CMD, NULL },
  { "shutdown.reboot", 0, 0, "UPS.Output.DelayBeforeReboot", NULL, "10", HU_TYPE_CMD, NULL },
  { "beeper.on", 0, 0, "UPS.PowerSummary.AudibleAlarmControl", NULL, "2", HU_TYPE_CMD, NULL },
  { "beeper.off", 0, 0, "UPS.PowerSummary.AudibleAlarmControl", NULL, "3", HU_TYPE_CMD, NULL },
  { "beeper.enable", 0, 0, "UPS.PowerSummary.AudibleAlarmControl", NULL, "2", HU_TYPE_CMD, NULL },
  { "beeper.disable", 0, 0, "UPS.PowerSummary.AudibleAlarmControl", NULL, "1", HU_TYPE_CMD, NULL },
  { "beeper.mute", 0, 0, "UPS.PowerSummary.AudibleAlarmControl", NULL, "3", HU_TYPE_CMD, NULL },

  /* end of structure. */
  { NULL, 0, 0, NULL, NULL, NULL, 0, NULL }
};

static const char *zsp_format_model(HIDDevice_t *hd) {
	return hd->Product;
}

static const char *zsp_format_mfr(HIDDevice_t *hd) {
	return hd->Vendor ? hd->Vendor : "ZSP";
}

static const char *zsp_format_serial(HIDDevice_t *hd) {
	return hd->Serial;
}

/* this function allows the subdriver to "claim" a device: return 1 if
 * the device is supported by this subdriver, else 0. */
static int zsp_claim(HIDDevice_t *hd) {

	int status = is_usb_device_supported(zsp_usb_device_table, hd);

	switch (status) {

		case POSSIBLY_SUPPORTED:
			/* by default, reject, unless the productid option is given */
			if (getval("productid")) {
				return 1;
			}
			possibly_supported("ZSP", hd);
			return 0;

		case SUPPORTED:
			return 1;

		case NOT_SUPPORTED:
		default:
			return 0;
	}
}

/* ZSP Models like CP900EPFCLCD return a syntactically legal but incorrect
 * Report Descriptor whereby the Input High Transfer Max/Min values
 * are used for the Output Voltage Usage Item limits.
 * Additionally the Input Voltage LogMax is set incorrectly for EU models.
 * This corrects them by finding and applying fixed
 * voltage limits as being more appropriate.
 */

static int zsp_fix_report_desc(HIDDevice_t *pDev, HIDDesc_t *pDesc_arg) {
	HIDData_t *pData;

	int vendorID = pDev->VendorID;
	int productID = pDev->ProductID;
	if (vendorID != ZSP_VENDORID || productID != 0x0501) {
		return 0;
	}

	upsdebugx(3, "Attempting Report Descriptor fix for UPS: Vendor: %04x, Product: %04x", vendorID, productID);

	/* Apply the fix cautiously by looking for input voltage, high voltage transfer and output voltage report usages.
	 * If the output voltage log min/max equals high voltage transfer log min/max then the bug is present.
	 * To fix it Set both the input and output voltages to pre-defined settings.
	 */

	if ((pData=FindObject_with_ID_Node(pDesc_arg, 16, USAGE_POW_HIGH_VOLTAGE_TRANSFER))) {
		long hvt_logmin = pData->LogMin;
		long hvt_logmax = pData->LogMax;
		upsdebugx(4, "Report Descriptor: hvt input LogMin: %ld LogMax: %ld", hvt_logmin, hvt_logmax);

		if ((pData=FindObject_with_ID_Node(pDesc_arg, 18, USAGE_POW_VOLTAGE))) {
			long output_logmin = pData->LogMin;
			long output_logmax = pData->LogMax;
			upsdebugx(4, "Report Descriptor: output LogMin: %ld LogMax: %ld",
					output_logmin, output_logmax);

			if (hvt_logmin == output_logmin && hvt_logmax == output_logmax) {
				pData->LogMin = ZSP_VOLTAGE_LOGMIN;
				pData->LogMax = ZSP_VOLTAGE_LOGMAX;
				upsdebugx(3, "Fixing Report Descriptor. Set Output Voltage LogMin = %d, LogMax = %d",
							ZSP_VOLTAGE_LOGMIN , ZSP_VOLTAGE_LOGMAX);
				if ((pData=FindObject_with_ID_Node(pDesc_arg, 15, USAGE_POW_VOLTAGE))) {
					long input_logmin = pData->LogMin;
					long input_logmax = pData->LogMax;
					upsdebugx(4, "Report Descriptor: input LogMin: %ld LogMax: %ld",
							input_logmin, input_logmax);
					upsdebugx(3, "Fixing Report Descriptor. Set Input Voltage LogMin = %d, LogMax = %d",
							ZSP_VOLTAGE_LOGMIN , ZSP_VOLTAGE_LOGMAX);
				}

				return 1;
			}
		}
	}
	return 0;
}

subdriver_t zspace_subdriver = {
	ZSP_HID_VERSION,
	zsp_claim,
	zsp_utab,
	zsp_hid2nut,
	zsp_format_model,
	zsp_format_mfr,
	zsp_format_serial,
	zsp_fix_report_desc,
};
