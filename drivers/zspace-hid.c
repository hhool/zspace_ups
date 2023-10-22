/* zspace-hid.c - subdriver to monitor Zspace USB/HID devices with NUT
 *
 *  Copyright (C)
 *  2003 - 2012	Arnaud Quette <ArnaudQuette@Eaton.com>
 *  2005 - 2006	Peter Selinger <selinger@users.sourceforge.net>
 *  2008 - 2009	Arjen de Korte <adkorte-guest@alioth.debian.org>
 *  2013 Charles Lepple <clepple+nut@gmail.com>
 *
 *  TODO: Add year and name for new subdriver author (contributor)
 *  Mention in docs/acknowledgements.txt if this is a vendor contribution
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
 */

#include "usbhid-ups.h"
#include "zspace-hid.h"
#include "main.h"	/* for getval() */
#include "usb-common.h"

#define ZSPACE_HID_VERSION	"Zspace HID 0.1"
/* FIXME: experimental flag to be put in upsdrv_info */

/* Zspace */
#define ZSPACE_VENDORID	0x036AA

/* USB IDs device table */
static usb_device_id_t zspace_usb_device_table[] = {
	/* Zspace */
	{ USB_DEVICE(ZSPACE_VENDORID, 0x0101), NULL },

	/* Terminating entry */
	{ 0, 0, NULL }
};


/* --------------------------------------------------------------- */
/*      Vendor-specific usage table */
/* --------------------------------------------------------------- */

/* ZSPACE usage table */
static usage_lkp_t zspace_usage_lkp[] = {
	{ "ZSPACE1",	0x0085006e },
	{ "ZSPACE2",	0x0085006f },
	{ NULL, 0 }
};

static usage_tables_t zspace_utab[] = {
	zspace_usage_lkp,
	hid_usage_lkp,
	NULL,
};

/* --------------------------------------------------------------- */
/* HID2NUT lookup table                                            */
/* --------------------------------------------------------------- */

static hid_info_t zspace_hid2nut[] = {

	{ "unmapped.ups.powersummary.capacitygranularity1", 0, 0, "UPS.PowerSummary.CapacityGranularity1", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.powersummary.capacitygranularity2", 0, 0, "UPS.PowerSummary.CapacityGranularity2", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.powersummary.capacitymode", 0, 0, "UPS.PowerSummary.CapacityMode", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.powersummary.configvoltage", 0, 0, "UPS.PowerSummary.ConfigVoltage", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.powersummary.designcapacity", 0, 0, "UPS.PowerSummary.DesignCapacity", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.powersummary.fullchargecapacity", 0, 0, "UPS.PowerSummary.FullChargeCapacity", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.powersummary.idevicechemistry", 0, 0, "UPS.PowerSummary.iDeviceChemistry", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.powersummary.imanufacturer", 0, 0, "UPS.PowerSummary.iManufacturer", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.powersummary.ioeminformation", 0, 0, "UPS.PowerSummary.iOEMInformation", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.powersummary.iproduct", 0, 0, "UPS.PowerSummary.iProduct", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.powersummary.presentstatus.acpresent", 0, 0, "UPS.PowerSummary.PresentStatus.ACPresent", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.powersummary.presentstatus.batterypresent", 0, 0, "UPS.PowerSummary.PresentStatus.BatteryPresent", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.powersummary.presentstatus.belowremainingcapacitylimit", 0, 0, "UPS.PowerSummary.PresentStatus.BelowRemainingCapacityLimit", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.powersummary.presentstatus.charging", 0, 0, "UPS.PowerSummary.PresentStatus.Charging", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.powersummary.presentstatus.discharging", 0, 0, "UPS.PowerSummary.PresentStatus.Discharging", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.powersummary.presentstatus.fullycharged", 0, 0, "UPS.PowerSummary.PresentStatus.FullyCharged", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.powersummary.presentstatus.remainingtimelimitexpired", 0, 0, "UPS.PowerSummary.PresentStatus.RemainingTimeLimitExpired", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.powersummary.rechargeable", 0, 0, "UPS.PowerSummary.Rechargeable", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.powersummary.remainingcapacity", 0, 0, "UPS.PowerSummary.RemainingCapacity", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.powersummary.remainingcapacitylimit", 0, 0, "UPS.PowerSummary.RemainingCapacityLimit", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.powersummary.remainingtimelimit", 0, 0, "UPS.PowerSummary.RemainingTimeLimit", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.powersummary.runtimetoempty", 0, 0, "UPS.PowerSummary.RunTimeToEmpty", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.powersummary.voltage", 0, 0, "UPS.PowerSummary.Voltage", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.powersummary.warningcapacitylimit", 0, 0, "UPS.PowerSummary.WarningCapacityLimit", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.selectorrevision.absolutestateofcharge", 0, 0, "UPS.SelectorRevision.AbsoluteStateOfCharge", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.selectorrevision.zspace1", 0, 0, "UPS.SelectorRevision.ZSPACE1", NULL, "%.0f", 0, NULL },
	{ "unmapped.ups.selectorrevision.zspace2", 0, 0, "UPS.SelectorRevision.ZSPACE2", NULL, "%.0f", 0, NULL },

	/* end of structure. */
	{ NULL, 0, 0, NULL, NULL, NULL, 0, NULL }
};

static const char *zspace_format_model(HIDDevice_t *hd) {
	return hd->Product;
}

static const char *zspace_format_mfr(HIDDevice_t *hd) {
	return hd->Vendor ? hd->Vendor : "Zspace";
}

static const char *zspace_format_serial(HIDDevice_t *hd) {
	return hd->Serial;
}

/* this function allows the subdriver to "claim" a device: return 1 if
 * the device is supported by this subdriver, else 0. */
static int zspace_claim(HIDDevice_t *hd)
{
	int status = is_usb_device_supported(zspace_usb_device_table, hd);

	switch (status)
	{
	case POSSIBLY_SUPPORTED:
		/* by default, reject, unless the productid option is given */
		if (getval("productid")) {
			return 1;
		}
		possibly_supported("Zspace", hd);
		return 0;

	case SUPPORTED:
		return 1;

	case NOT_SUPPORTED:
	default:
		return 0;
	}
}

subdriver_t zspace_subdriver = {
	ZSPACE_HID_VERSION,
	zspace_claim,
	zspace_utab,
	zspace_hid2nut,
	zspace_format_model,
	zspace_format_mfr,
	zspace_format_serial,
	fix_report_desc,	/* may optionally be customized, see cps-hid.c for example */
};
