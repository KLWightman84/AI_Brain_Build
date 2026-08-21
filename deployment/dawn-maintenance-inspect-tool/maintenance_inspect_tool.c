/*
 * Read-only DAWN maintenance inspection tool.
 *
 * It deliberately does not spawn a shell, invoke a command, modify a file,
 * restart a service, or access secrets.  Actions requiring owner approval
 * remain the responsibility of the external aibrain-maintenance guard.
 */

#include "tools/maintenance_inspect_tool.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/statvfs.h>
#include <sys/sysinfo.h>

#include "config/dawn_config.h"
#include "llm/llm_local_provider.h"
#include "tools/tool_registry.h"

#define MAINTENANCE_INSPECT_RESULT_MAX 1024
#define BYTES_PER_GIB (1024.0 * 1024.0 * 1024.0)

static char *maintenance_inspect_tool_callback(const char *action, char *value,
                                                int *should_respond);

static const tool_metadata_t maintenance_inspect_metadata = {
    .name = "maintenance_inspect",
    .device_string = "maintenance inspection",
    .topic = "dawn",
    .aliases = { "maintenance", "maintenance status", "system inspection" },
    .alias_count = 3,
    .description =
        "Report a concise, read-only maintenance inspection for this DAWN host: local LLM "
        "context availability, filesystem space, memory, and load. This tool cannot repair, "
        "upgrade, restart services, change configuration, run commands, access secrets, or "
        "modify files. Use its result to diagnose and propose an owner-approved next step.",
    .params = NULL,
    .param_count = 0,
    .device_type = TOOL_DEVICE_TYPE_GETTER,
    .capabilities = TOOL_CAP_INFORMATIONAL,
    .is_getter = true,
    .skip_followup = false,
    .default_local = true,
    .default_remote = true,
    .config = NULL,
    .config_size = 0,
    .config_parser = NULL,
    .config_writer = NULL,
    .config_section = NULL,
    .secret_requirements = NULL,
    .init = NULL,
    .cleanup = NULL,
    .callback = maintenance_inspect_tool_callback,
};

static char *maintenance_inspect_tool_callback(const char *action, char *value,
                                                int *should_respond) {
   (void)action;
   (void)value;

   if (should_respond != NULL) {
      *should_respond = 1;
   }

   char *result = calloc(1, MAINTENANCE_INSPECT_RESULT_MAX);
   if (result == NULL) {
      return NULL;
   }

   struct statvfs filesystem;
   struct sysinfo memory;
   double disk_free_gib = -1.0;
   double disk_total_gib = -1.0;
   double memory_free_gib = -1.0;
   double memory_total_gib = -1.0;
   double load_1m = -1.0;
   int local_context = 0;

   if (statvfs("/srv/aibrain", &filesystem) == 0) {
      disk_free_gib = ((double)filesystem.f_bavail * (double)filesystem.f_frsize) / BYTES_PER_GIB;
      disk_total_gib = ((double)filesystem.f_blocks * (double)filesystem.f_frsize) / BYTES_PER_GIB;
   }

   if (sysinfo(&memory) == 0) {
      memory_free_gib = ((double)memory.freeram * (double)memory.mem_unit) / BYTES_PER_GIB;
      memory_total_gib = ((double)memory.totalram * (double)memory.mem_unit) / BYTES_PER_GIB;
   }

   double loads[3];
   if (getloadavg(loads, 3) > 0) {
      load_1m = loads[0];
   }

   if (g_config.llm.local.endpoint[0] != '\0') {
      local_context = llm_local_query_context_size(g_config.llm.local.endpoint,
                                                   g_config.llm.local.model);
   }

   char context_status[64];
   char disk_status[96];
   char memory_status[96];
   char load_status[64];

   if (local_context > 0) {
      snprintf(context_status, sizeof(context_status), "%d tokens", local_context);
   } else {
      snprintf(context_status, sizeof(context_status), "unavailable");
   }
   if (disk_free_gib >= 0.0 && disk_total_gib >= 0.0) {
      snprintf(disk_status, sizeof(disk_status), "%.1f / %.1f GiB free", disk_free_gib,
               disk_total_gib);
   } else {
      snprintf(disk_status, sizeof(disk_status), "unavailable");
   }
   if (memory_free_gib >= 0.0 && memory_total_gib >= 0.0) {
      snprintf(memory_status, sizeof(memory_status), "%.1f / %.1f GiB free", memory_free_gib,
               memory_total_gib);
   } else {
      snprintf(memory_status, sizeof(memory_status), "unavailable");
   }
   if (load_1m >= 0.0) {
      snprintf(load_status, sizeof(load_status), "%.2f", load_1m);
   } else {
      snprintf(load_status, sizeof(load_status), "unavailable");
   }

   snprintf(result, MAINTENANCE_INSPECT_RESULT_MAX,
            "Maintenance inspection (read-only): DAWN is serving this request. "
            "Local LLM context: %s. Disk /srv/aibrain: %s. Memory: %s. One-minute load: %s. "
            "Scope: inspection only; no service restart, configuration, package, model, or file "
            "change is permitted.",
            context_status, disk_status, memory_status, load_status);

   return result;
}

int maintenance_inspect_tool_register(void) {
   return tool_registry_register(&maintenance_inspect_metadata);
}
