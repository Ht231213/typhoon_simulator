extends RefCounted
## IBTrACS v04r01 的 **174 列列名 / 单位**，逐字取自官方 CSV 表头（NOAA NCEI）。
##
## 数据来源（2026-10-25 抓取，只取了前 200 KB 的表头）：
##   https://www.ncei.noaa.gov/data/international-best-track-archive-for-climate-stewardship-ibtracs/v04r01/access/csv/ibtracs.WP.list.v04r01.csv
##   第 1 行 = 174 个列名，第 2 行 = 174 个单位（缺失值在官方文件里是**一个空格**）。
##
## ⚠ **这个文件不要手改**：列顺序就是格式的一部分，错一列整份 CSV 的字段全错位。
##   格式说明见 `docs/研究/02-IBTrACS格式与字段映射.md` §2。

const COLUMNS: Array[String] = [
	"SID", "SEASON", "NUMBER", "BASIN", "SUBBASIN", "NAME",
	"ISO_TIME", "NATURE", "LAT", "LON", "WMO_WIND", "WMO_PRES",
	"WMO_AGENCY", "TRACK_TYPE", "DIST2LAND", "LANDFALL", "IFLAG", "USA_AGENCY",
	"USA_ATCF_ID", "USA_LAT", "USA_LON", "USA_RECORD", "USA_STATUS", "USA_WIND",
	"USA_PRES", "USA_SSHS", "USA_R34_NE", "USA_R34_SE", "USA_R34_SW", "USA_R34_NW",
	"USA_R50_NE", "USA_R50_SE", "USA_R50_SW", "USA_R50_NW", "USA_R64_NE", "USA_R64_SE",
	"USA_R64_SW", "USA_R64_NW", "USA_POCI", "USA_ROCI", "USA_RMW", "USA_EYE",
	"TOKYO_LAT", "TOKYO_LON", "TOKYO_GRADE", "TOKYO_WIND", "TOKYO_PRES", "TOKYO_R50_DIR",
	"TOKYO_R50_LONG", "TOKYO_R50_SHORT", "TOKYO_R30_DIR", "TOKYO_R30_LONG", "TOKYO_R30_SHORT", "TOKYO_LAND",
	"CMA_LAT", "CMA_LON", "CMA_CAT", "CMA_WIND", "CMA_PRES", "HKO_LAT",
	"HKO_LON", "HKO_CAT", "HKO_WIND", "HKO_PRES", "KMA_LAT", "KMA_LON",
	"KMA_CAT", "KMA_WIND", "KMA_PRES", "KMA_R50_DIR", "KMA_R50_LONG", "KMA_R50_SHORT",
	"KMA_R30_DIR", "KMA_R30_LONG", "KMA_R30_SHORT", "NEWDELHI_LAT", "NEWDELHI_LON", "NEWDELHI_GRADE",
	"NEWDELHI_WIND", "NEWDELHI_PRES", "NEWDELHI_CI", "NEWDELHI_DP", "NEWDELHI_POCI", "REUNION_LAT",
	"REUNION_LON", "REUNION_TYPE", "REUNION_WIND", "REUNION_PRES", "REUNION_TNUM", "REUNION_CI",
	"REUNION_RMW", "REUNION_R34_NE", "REUNION_R34_SE", "REUNION_R34_SW", "REUNION_R34_NW", "REUNION_R50_NE",
	"REUNION_R50_SE", "REUNION_R50_SW", "REUNION_R50_NW", "REUNION_R64_NE", "REUNION_R64_SE", "REUNION_R64_SW",
	"REUNION_R64_NW", "BOM_LAT", "BOM_LON", "BOM_TYPE", "BOM_WIND", "BOM_PRES",
	"BOM_TNUM", "BOM_CI", "BOM_RMW", "BOM_R34_NE", "BOM_R34_SE", "BOM_R34_SW",
	"BOM_R34_NW", "BOM_R50_NE", "BOM_R50_SE", "BOM_R50_SW", "BOM_R50_NW", "BOM_R64_NE",
	"BOM_R64_SE", "BOM_R64_SW", "BOM_R64_NW", "BOM_ROCI", "BOM_POCI", "BOM_EYE",
	"BOM_POS_METHOD", "BOM_PRES_METHOD", "NADI_LAT", "NADI_LON", "NADI_CAT", "NADI_WIND",
	"NADI_PRES", "WELLINGTON_LAT", "WELLINGTON_LON", "WELLINGTON_WIND", "WELLINGTON_PRES", "DS824_LAT",
	"DS824_LON", "DS824_STAGE", "DS824_WIND", "DS824_PRES", "TD9636_LAT", "TD9636_LON",
	"TD9636_STAGE", "TD9636_WIND", "TD9636_PRES", "TD9635_LAT", "TD9635_LON", "TD9635_WIND",
	"TD9635_PRES", "TD9635_ROCI", "NEUMANN_LAT", "NEUMANN_LON", "NEUMANN_CLASS", "NEUMANN_WIND",
	"NEUMANN_PRES", "MLC_LAT", "MLC_LON", "MLC_CLASS", "MLC_WIND", "MLC_PRES",
	"USA_GUST", "BOM_GUST", "BOM_GUST_PER", "REUNION_GUST", "REUNION_GUST_PER", "USA_SEAHGT",
	"USA_SEARAD_NE", "USA_SEARAD_SE", "USA_SEARAD_SW", "USA_SEARAD_NW", "STORM_SPEED", "STORM_DIR",
]

const UNITS: Array[String] = [
	" ", "Year", " ", " ", " ", " ",
	" ", " ", "degrees_north", "degrees_east", "kts", "mb",
	" ", " ", "km", "km", " ", " ",
	" ", "degrees_north", "degrees_east", " ", " ", "kts",
	"mb", "1", "nmile", "nmile", "nmile", "nmile",
	"nmile", "nmile", "nmile", "nmile", "nmile", "nmile",
	"nmile", "nmile", "mb", "nmile", "nmile", "nmile",
	"degrees_north", "degrees_east", "1", "kts", "mb", " ",
	"nmile", "nmile", " ", "nmile", "nmile", "1",
	"degrees_north", "degrees_east", "1", "kts", "mb", "degrees_north",
	"degrees_east", " ", "kts", "mb", "degrees_north", "degrees_east",
	" ", "kts", "mb", " ", "nmile", "nmile",
	" ", "nmile", "nmile", "degrees_north", "degrees_east", " ",
	"kts", "mb", "1", "mb", "mb", "degrees_north",
	"degrees_east", " ", "kts", "mb", "1", "1",
	"nmile", "nmile", "nmile", "nmile", "nmile", "nmile",
	"nmile", "nmile", "nmile", "nmile", "nmile", "nmile",
	"nmile", "degrees_north", "degrees_east", " ", "kts", "mb",
	"1", "1", "nmile", "nmile", "nmile", "nmile",
	"nmile", "nmile", "nmile", "nmile", "nmile", "nmile",
	"nmile", "nmile", "nmile", "nmile", "mb", "nmile",
	" ", " ", "degrees_north", "degrees_east", "1", "kts",
	"mb", "degrees_north", "degrees_east", "kts", "mb", "degrees_north",
	"degrees_east", " ", "kts", "mb", "degrees_north", "degrees_east",
	" ", "kts", "mb", "degrees_north", "degrees_east", "kts",
	"mb", "nmile", "degrees_north", "degrees_east", " ", "kts",
	"mb", "degrees_north", "degrees_east", " ", "kts", "mb",
	"kts", "kts", "second", "kts", "second", "ft",
	"nmile", "nmile", "nmile", "nmile", "kts", "degrees",
]

## 列数（官方固定 174，改动会破坏兼容性）
static func count() -> int:
	return COLUMNS.size()
