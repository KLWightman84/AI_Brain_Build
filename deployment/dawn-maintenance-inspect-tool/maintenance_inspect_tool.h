/*
 * Read-only DAWN maintenance inspection tool.
 *
 * This tool intentionally reports only local health indicators. It does not
 * run commands, alter configuration, restart services, or apply upgrades.
 */

#ifndef MAINTENANCE_INSPECT_TOOL_H
#define MAINTENANCE_INSPECT_TOOL_H

/** Register the maintenance_inspect tool with DAWN's tool registry. */
int maintenance_inspect_tool_register(void);

#endif /* MAINTENANCE_INSPECT_TOOL_H */
