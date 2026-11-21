// SPDX-License-Identifier: Apache-2.0
static inline int s2a_betop_brand(const char *s) {
    return strcasestr(s, "beitong") || strcasestr(s, "betop") || strstr(s, "北通");
}

static inline int s2a_hidg_betop_ns(const char *manufacturer, const char *name, int vid, int pid) {
    return (s2a_betop_brand(manufacturer) || s2a_betop_brand(name)) &&
           ((vid == 0x057e && pid == 0x2009) || strcasestr(name, "switch") || strcasestr(name, "NS mode"));
}
