// Azure Local Sizer (ODIN) — a custom solution for RVTools Analyzer.
//
// 1) Sizes the selected VMs onto Azure Local nodes (CPU, memory, Storage Spaces Direct capacity) and shows every
//    node count from 2 to 16, so you can see where the cluster stops being constrained.
// 2) Builds an "Open in ODIN" link: the same workloads, node hardware and resiliency pre-loaded in
//    https://azure.github.io/odinforazurelocal/sizer/ so ODIN's own sizing can confirm or override the estimate.
//
// It never downloads anything. The local estimate is a planning aid; ODIN is the authority.
const ODIN_SIZER = "https://azure.github.io/odinforazurelocal/sizer/";
const MAX_URL = 7500; // fall back to one grouped workload beyond this
const MAX_NODES = 16;
const ARB_VCPU = 4;
const ARB_MEMORY_GB = 8;
const PLATFORM_VOLUMES_GB = 276;
const HOST_MEMORY_BASE_GB = 32;
const AUTO_MEMORY_CAP_GB = 2048;
const SMALL_CLUSTER_MEMORY_CAP_GB = 1536;
const CPU_HEADROOM = 0.80;
const MEMORY_HEADROOM = 0.85;
const STORAGE_HEADROOM = 0.80;
const AUTO_NODE_OPTIONS = Array.from({ length: MAX_NODES - 1 }, (_, i) => i + 2);
const MANUAL_NODE_OPTIONS = [2, 3, 4, 5, 6, 7, 8, 12, 16];
const GROWTH_PCT = [0, 10, 20, 30, 50];
const VCPU_RATIOS = [1, 2, 3, 4, 5, 6];
const RESILIENCY = ["2way", "3way"];
const DISK_TB = [0.96, 1.92, 3.84, 5.68, 7.68, 8, 12, 15.36, 16, 20];
// Memory per machine options — copied from ODIN's sizer/sizer.js (MEMORY_OPTIONS_GB).
const MEMORY_OPTIONS_GB = [64, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096];
const FIXED_CORE_OPTIONS = [4, 8, 10, 12, 16, 18, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 60, 64, 72, 80, 84, 86, 96, 112, 128, 144, 160, 172, 192];

// CPU generations and their "CPU Cores per Socket" options — copied from ODIN's sizer/sizer.js (CPU_GENERATIONS).
// The order here must match the "CPU generation" options in manifest.json.
const GENERATIONS = [
  { manufacturer: "intel", id: "xeon-4th", name: "Intel® 4th Gen Xeon® (Sapphire Rapids)", cores: [8, 12, 16, 24, 32, 40, 48, 56, 60], defaultCores: 24 },
  { manufacturer: "intel", id: "xeon-5th", name: "Intel® 5th Gen Xeon® (Emerald Rapids)", cores: [8, 10, 12, 16, 18, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 60, 64, 80, 96, 128], defaultCores: 24 },
  { manufacturer: "intel", id: "xeon-6", name: "Intel® 6th Gen Xeon® (Granite Rapids / Sierra Forest)", cores: [8, 12, 16, 24, 32, 36, 48, 64, 72, 80, 86, 96, 128, 144, 172], defaultCores: 32 },
  { manufacturer: "amd", id: "epyc-4th", name: "AMD 4th Gen EPYC™ (Genoa)", cores: [8, 16, 24, 32, 48, 64, 84, 96], defaultCores: 24 },
  { manufacturer: "amd", id: "epyc-4th-c", name: "AMD 4th Gen EPYC™ (Bergamo, Zen 4c)", cores: [8, 16, 32, 64, 112, 128], defaultCores: 64 },
  { manufacturer: "amd", id: "epyc-5th", name: "AMD 5th Gen EPYC™ (Turin)", cores: [8, 16, 24, 32, 36, 48, 64, 72, 84, 128], defaultCores: 32 },
  { manufacturer: "amd", id: "epyc-5th-c", name: "AMD 5th Gen EPYC™ (Turin Dense, Zen 5c)", cores: [96, 128, 144, 160, 192], defaultCores: 128 },
  { manufacturer: "intel_edge", id: "xeon-d-27xx", name: "Intel® Xeon® D-2700 (Ice Lake-D)", cores: [4, 8, 10, 12, 16, 20], defaultCores: 8 },
];
function run(vms, inventory, params, context) {
  const checks = rva.checks();
  const inScope = vms.filter((vm) => !vm.isTemplate);
  if (inScope.length === 0) {
    return { headline: "No VMs selected", sections: [checks.section("Considerations")] };
  }

  // ---- Workload demand ----------------------------------------------------
  const demandOptions = { rightsizeCPU: params.rightsize, rightsizeMemory: params.rightsize, bufferPct: params.buffer, minVCPU: 1, minMemoryGiB: 1 };
  const growthPct = GROWTH_PCT[params.growth] ?? 10;
  const growth = 1 + growthPct / 100;
  const demands = inScope.map((vm) => {
    const d = rva.cloud.demand(vm, demandOptions);
    return {
      vm, vcpu: d.vcpu,
      memoryGB: Math.round(d.memoryGiB),
      storageGB: Math.round(diskTotal(d.diskGiB)),
    };
  });
  const need = {
    vcpu: Math.ceil(rva.sum(demands, "vcpu") * growth),
    memoryGB: Math.ceil(rva.sum(demands, "memoryGB") * growth),
    storageGB: Math.ceil(rva.sum(demands, "storageGB") * growth),
  };

  // ---- Node hardware ------------------------------------------------------
  const gen = GENERATIONS[params.generation] || GENERATIONS[3];
  const baseHW = {
    ratio: VCPU_RATIOS[params.vcpuRatio] ?? 4,
    diskCount: params.diskCount,
    autoDisks: !!params.autoDisks,
    maxDisks: Math.min(40, Math.max(params.maxDisks || params.diskCount, params.diskCount)),
    diskTB: DISK_TB[params.diskSize] ?? 3.84,
  };
  baseHW.diskGB = baseHW.diskTB * 1024;
  const wantResiliency = params.resiliency === 0 ? 0 : 1; // index into RESILIENCY

  // ---- Evaluate every node count -----------------------------------------
  const fixedNodeCount = MANUAL_NODE_OPTIONS[params.nodeCount] || null;
  const fixed = params.sizingMode === 1 ? fixedNodeCount : null;
  const requestedFixedCores = FIXED_CORE_OPTIONS[params.fixedCores] ?? gen.defaultCores;
  const fixedHW = fixed ? {
    sockets: params.fixedSockets === 0 ? 1 : 2,
    coresPerSocket: nearestSupportedCoreCount(gen, requestedFixedCores),
    memoryGB: MEMORY_OPTIONS_GB[params.fixedMemory] ?? 512,
  } : null;
  const initialNodeCount = fixed || recommendNodeCount(need, gen, baseHW, wantResiliency);
  let chosen;
  if (fixed) {
    chosen = sizeForNodeCount(fixed, need, gen, baseHW, wantResiliency, undefined, false, fixedHW);
    if (fixedHW.coresPerSocket !== requestedFixedCores) {
      checks.add("fixed-cores-adjusted", "Node hardware", `${requestedFixedCores} cores per socket is not offered for ${gen.name}`,
        "info", `The fixed configuration uses ${fixedHW.coresPerSocket} cores per socket, the nearest core count supported by ODIN for this CPU generation.`);
    }
  } else {
    let cpuFloor = gen.defaultCores;
    for (let n = initialNodeCount; n <= MAX_NODES; n++) {
      const candidate = sizeForNodeCount(n, need, gen, baseHW, wantResiliency, cpuFloor);
      cpuFloor = candidate.hw.coresPerSocket;
      if (candidate.conservativeFit) {
        chosen = candidate;
        break;
      }
    }
    if (!chosen) {
      for (let n = initialNodeCount; n <= MAX_NODES; n++) {
        const candidate = sizeForNodeCount(n, need, gen, baseHW, wantResiliency, cpuFloor, true);
        cpuFloor = candidate.hw.coresPerSocket;
        if (candidate.fits) {
          chosen = candidate;
          break;
        }
      }
    }
    if (!chosen) chosen = sizeForNodeCount(MAX_NODES, need, gen, baseHW, wantResiliency, cpuFloor, true);
    if (chosen.n === 2 && chosen.hw.memoryGB > 768) {
      const threeNode = sizeForNodeCount(3, need, gen, baseHW, wantResiliency, gen.defaultCores);
      if (threeNode.conservativeFit) chosen = threeNode;
    }
  }
  const hw = Object.assign({}, chosen.hw, { diskCount: chosen.disks, diskTB: chosen.diskTB, diskGB: chosen.diskGB });
  const rowHW = Object.assign({}, hw, { diskCount: baseHW.diskCount, diskTB: baseHW.diskTB, diskGB: baseHW.diskGB });
  const rows = AUTO_NODE_OPTIONS.map((n) => evaluate(n, need, rowHW, wantResiliency));
  const firstFit = rows.find((r) => r.conservativeFit);

  if (!fixed && !chosen.fits) {
    checks.add("nofit", "Sizing", `Does not fit in ${MAX_NODES} nodes`, "warning",
      `At ${MAX_NODES} nodes the limiting resource is: ${rows[rows.length - 1].limits.join(", ")}. `
        + `Demand is ${rva.int(need.vcpu)} vCPU, ${rva.num(need.memoryGB, 0)} GB memory and ${rva.num(need.storageGB / 1000, 1)} TB storage.`,
      { remediation: "Raise the limiting resource: memory or cores per node, the maximum capacity disks, or a larger disk size — or split the VMs across clusters." });
  }
  if (fixed && !chosen.fits) {
    checks.add("fixed-nofit", "Sizing", `${fixed} nodes is not enough`, "warning",
      `Over capacity on: ${chosen.limits.join(", ")}.`,
      { remediation: firstFit ? `ODIN-style headroom is reached at ${firstFit.n} nodes with the selected per-node specification.` : "Increase the node specification or reduce workload demand." });
  }
  if (wantResiliency === 1 && chosen.n < 3) {
    checks.add("res", "Sizing", "Three-way mirror needs 3+ nodes", "info", `${chosen.n} nodes was evaluated with a two-way mirror.`);
  }
  const off = inScope.filter((vm) => !vm.isRunning);
  if (off.length) {
    checks.add("off", "Scope", "Powered-off VMs are included", "info",
      `${off.length} powered-off VMs are sized like running ones. Change the selection to powered-on only if that is not what you want.`,
      { affected: off.map((vm) => rva.vmRef(vm)) });
  }

  // ---- ODIN link ----------------------------------------------------------
  const clusterName = "RVTools-AzL";
  const hwOut = hw;
  let url = odinUrl(buildConfig(clusterName, chosen.n, !!fixed, params, hwOut, wantResiliency, demands, need, params.grouping === 1));
  if (params.grouping === 1 && url.length > MAX_URL) {
    checks.add("url", "ODIN link", "Link too long for per-VM workloads", "info",
      `${rva.int(inScope.length)} workloads would make a ${rva.int(url.length)}-character link, so one grouped workload is used instead.`);
    url = odinUrl(buildConfig(clusterName, chosen.n, !!fixed, params, hwOut, wantResiliency, demands, need, false));
  }

  // ---- Presentation -------------------------------------------------------
  const sections = [];
  const pct = (x) => rva.num(x * 100, 0) + "%";
  sections.push(rva.metrics("Automatic hardware sizing", [
    rva.metric("CPU topology", `${hw.sockets} × ${hw.coresPerSocket} cores`, `${hw.cores} physical cores/node · ${rva.int(chosen.cpuCap)} vCPU capacity for ${chosen.n} nodes with N+1`, "cpu"),
    rva.metric("Memory per node", `${hw.memoryGB} GB`, `${rva.num(chosen.memCap, 0)} GB usable with host reserve and N+1`, "memorychip"),
  ]));
  sections.push(rva.metrics("Summary", [
    rva.metric("Nodes", String(chosen.n), chosen.fits ? (fixed ? "Fixed node count" : "Best-fit configuration") : "Over capacity", chosen.fits ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"),
    rva.metric("vCPU", rva.int(need.vcpu), `${pct(chosen.cpuUtil)} of ${rva.int(chosen.cpuCap)} schedulable`, "cpu"),
    rva.metric("Memory", rva.num(need.memoryGB, 0) + " GB", `${pct(chosen.memUtil)} of ${rva.num(chosen.memCap, 0)} GB usable`, "memorychip"),
    rva.metric("Storage", rva.num(need.storageGB / 1000, 1) + " TB", `${pct(chosen.stoUtil)} of ${rva.num(chosen.stoCap / 1000, 1)} TB usable (${chosen.disks} disks/node)`, "externaldrive"),
  ]));

  sections.push(rva.table({
    id: "hardware",
    title: "Final server hardware specification",
    columns: ["Specification", "Selected configuration"],
    rows: [
      ["Cluster", `${chosen.n} Azure Local nodes${fixed ? " (fixed)" : " (automatic)"}`],
      ["CPU generation", gen.name],
      ["Processors per node", `${hw.sockets} socket${hw.sockets === 1 ? "" : "s"}`],
      ["Cores per socket", String(hw.coresPerSocket)],
      ["Physical cores per node", String(hw.cores)],
      ["vCPU : physical core ratio", `${hw.ratio}:1`],
      ["Memory per node", `${hw.memoryGB} GB`],
      ["Host memory reserve", `${chosen.hostMemoryGB} GB per node`],
      ["Azure Resource Bridge reserve", `${ARB_VCPU} vCPU and ${ARB_MEMORY_GB} GB per cluster`],
      ["Volume resiliency", chosen.resiliencyLabel],
      ["Capacity disks", `${chosen.disks} per node × ${chosen.diskTB} TB`],
    ],
  }));

  sections.push(rva.table({
    id: "nodes",
    title: "Every node count",
    subtitle: `CPU and memory use the selected per-node configuration: ${gen.name}, ${hw.sockets} × ${hw.coresPerSocket} cores, ${hw.memoryGB} GB. Capacity disks are re-sized for each node count.`,
    columns: ["Nodes", "Resiliency", "Disks / node", "Disk size", "vCPU used", "Memory used", "Memory usable", "Storage used", "Fits", "Constrained by"],
    numeric: [0, 2, 4, 5, 6, 7],
    rows: rows.map((r) => [
      String(r.n), r.resiliencyLabel, String(r.disks), `${r.diskTB} TB`, pct(r.cpuUtil), pct(r.memUtil), `${rva.num(r.memCap, 0)} GB`, pct(r.stoUtil),
      r.fits ? "Yes" : "No", r.limits.join(", ") || "—",
    ]),
    emphasized: [chosen.n - 2],
  }));

  sections.push(checks.section("Considerations"));

  sections.push(rva.table({
    id: "workloads",
    title: "Workloads sent to ODIN",
    subtitle: "Per-VM demand before growth; the ODIN link carries the totals" + (params.grouping === 1 ? " or one workload per VM when the link is short enough" : ""),
    columns: ["VM", "Cluster", "OS", "vCPU", "Memory (GB)", "Storage (GB)"],
    numeric: [3, 4, 5],
    rows: demands.map((d) => [d.vm.name, d.vm.clusterName, d.vm.os.name, rva.int(d.vcpu), rva.num(d.memoryGB, 0), rva.num(d.storageGB, 0)]),
    rowRefs: demands.map((d) => rva.vmRef(d.vm)),
  }));

  sections.push(rva.notes("Open in ODIN", [
    "Copy this link into a browser to load the same workloads, node hardware and resiliency in ODIN for Azure Local:",
    url,
    "ODIN processes the configuration locally in the browser; nothing is sent from this app.",
  ]));

  sections.push(rva.notes("Method and assumptions", [
    `Demand: ${rva.int(inScope.length)} VMs, ${rva.int(need.vcpu)} vCPU, ${rva.num(need.memoryGB, 0)} GB memory, ${rva.num(need.storageGB, 0)} GB provisioned storage`
      + (params.rightsize ? `, right-sized from observed usage plus ${params.buffer}%` : "") + (growthPct ? `, plus ${growthPct}% growth.` : "."),
    `Auto starts at ODIN's default core count for ${gen.name}, scales upward through that generation's supported core options for fit and 80% CPU headroom, and uses two sockets per node. Auto begins at ODIN's recommended node count, snaps to its supported count, then adds nodes until utilization is below 90%. Fixed mode uses the selected sockets, cores per socket and memory without scaling; the ratio is ${hw.ratio}:1 in both modes.`,
    `CPU capacity reserves max(2 cores, 10% of physical cores) per node. Memory capacity reserves max(${HOST_MEMORY_BASE_GB} GB, 8% of node RAM), then deducts ${ARB_MEMORY_GB} GB for Azure Resource Bridge; both CPU and memory use N−1 effective nodes.`,
    `Storage uses ODIN's all-flash capacity-disk sizes and 1024 GB per TB, with up to ${hw.maxDisks} disks per node. It reserves up to four repair disks and ${PLATFORM_VOLUMES_GB} GB for Azure Local platform volumes, then targets 80% raw-storage utilization. Storage demand is provisioned disk capacity, matching ODIN's RVTools import.`,
    "RVTools sizing is scoped to VM workloads. ODIN's GPU and non-VM workload sizing is not included.",
  ]));

  const headline = chosen.fits
    ? `${rva.int(inScope.length)} VMs fit on ${chosen.n} Azure Local nodes (${hw.cores} cores, ${hw.memoryGB} GB each)`
    : `${rva.int(inScope.length)} VMs do not fit on ${chosen.n} nodes of this configuration — limited by ${chosen.limits.join(", ")}`;
    // ---- ODIN JSON file (ODIN's Import button; no URL length limit) ----
  const exportLayout = params.grouping === 1 ? 1 : (params.grouping === 2 && inScope.length <= 1000 ? 2 : 0);
  const odinState = buildConfig(clusterName, chosen.n, !!fixed, params, hwOut, wantResiliency, demands, need, exportLayout);
  const odinFile = {
    _meta: { tool: "ODIN Sizer for Azure Local", source: "RVTools Analyzer - Azure Local Sizer (ODIN) solution", exportedAt: new Date().toISOString() },
    data: odinState,
  };
  const day = new Date().toISOString().slice(0, 10);
  return { headline, sections, exports: [{
    title: "ODIN Sizer configuration (import with ODIN's Import button)",
    fileName: `odin-sizer_${odinState.clusterType}_${chosen.n}n_${odinState.workloads.length}wl_${day}.json`,
    content: JSON.stringify(odinFile, null, 2),
  }] };
}

function diskTotal(disks) {
  if (Array.isArray(disks)) return disks.reduce((t, g) => t + (Number(g) || 0), 0);
  return Number(disks) || 0;
}

function recommendNodeCount(need, generation, hw, wantResiliency) {
  const maxCores = generation.cores[generation.cores.length - 1] * 2;
  const maxHostCores = Math.max(2, Math.ceil(maxCores * 0.1));
  const computeNodes = Math.ceil((need.vcpu + ARB_VCPU) / Math.max((maxCores - maxHostCores) * hw.ratio, 1));
  const preferredMemory = SMALL_CLUSTER_MEMORY_CAP_GB;
  const preferredHostMemory = Math.max(HOST_MEMORY_BASE_GB, Math.ceil(preferredMemory * 0.08));
  const memoryNodes = Math.ceil((need.memoryGB + ARB_MEMORY_GB) / Math.max(preferredMemory - preferredHostMemory, 1));
  const recommendationDiskGB = Math.max(hw.diskGB, 15.36 * 1024);
  const repairGB = recommendationDiskGB;
  const factor = wantResiliency === 0 ? 2 : 3;
  const rawStorageNeed = need.storageGB * factor + PLATFORM_VOLUMES_GB * factor + repairGB;
  const storageNodes = Math.ceil(rawStorageNeed / Math.max(hw.maxDisks * recommendationDiskGB, 1));
  const withN1 = (nodes) => nodes >= 2 ? nodes + 1 : nodes;
  const minimum = wantResiliency === 0 ? 2 : 3;
  const recommended = Math.max(withN1(computeNodes), withN1(memoryNodes), storageNodes, minimum);
  return MANUAL_NODE_OPTIONS.find((nodes) => nodes >= recommended) || MAX_NODES;
}

function sizeForNodeCount(n, need, generation, baseHW, wantResiliency, minimumCores, allowHighMemory = false, fixedConfig = null) {
  const effectiveNodes = n > 1 ? n - 1 : 1;
  const startingCoreIndex = Math.max(0, generation.cores.findIndex((cores) => cores >= (minimumCores || generation.defaultCores)));
  let coreIndex = fixedConfig
    ? generation.cores.indexOf(fixedConfig.coresPerSocket)
    : startingCoreIndex;
  if (coreIndex < 0) coreIndex = startingCoreIndex;
  const sockets = fixedConfig ? fixedConfig.sockets : 2;
  const cpuCapacity = (coresPerSocket) => {
    const cores = coresPerSocket * sockets;
    const hostCores = Math.max(2, Math.ceil(cores * 0.1));
    return Math.max(cores - hostCores, 0) * effectiveNodes * baseHW.ratio - ARB_VCPU;
  };
  if (!fixedConfig) {
    while (coreIndex < generation.cores.length - 1 && cpuCapacity(generation.cores[coreIndex]) < need.vcpu) coreIndex++;
    while (coreIndex < generation.cores.length - 1 && need.vcpu / Math.max(cpuCapacity(generation.cores[coreIndex]), 1) > CPU_HEADROOM) coreIndex++;
  }
  const coresPerSocket = generation.cores[coreIndex];
  const cores = coresPerSocket * sockets;

  let memoryGB;
  if (fixedConfig) {
    memoryGB = fixedConfig.memoryGB;
  } else {
    const memoryLimit = allowHighMemory ? MEMORY_OPTIONS_GB[MEMORY_OPTIONS_GB.length - 1]
      : n < 10 ? SMALL_CLUSTER_MEMORY_CAP_GB : AUTO_MEMORY_CAP_GB;
    const memoryCapacity = (memory) => Math.max(0, (memory - Math.max(HOST_MEMORY_BASE_GB, Math.ceil(memory * 0.08))) * effectiveNodes - ARB_MEMORY_GB);
    let memoryIndex = MEMORY_OPTIONS_GB.findIndex((memory) => memory <= memoryLimit && memoryCapacity(memory) >= need.memoryGB);
    if (memoryIndex < 0) memoryIndex = MEMORY_OPTIONS_GB.findIndex((memory) => memory <= memoryLimit);
    if (memoryIndex < 0) memoryIndex = 0;
    while (memoryIndex < MEMORY_OPTIONS_GB.length - 1) {
      const nextMemory = MEMORY_OPTIONS_GB[memoryIndex + 1];
      if (nextMemory > memoryLimit || need.memoryGB / Math.max(memoryCapacity(MEMORY_OPTIONS_GB[memoryIndex]), 1) <= MEMORY_HEADROOM) break;
      memoryIndex++;
    }
    memoryGB = MEMORY_OPTIONS_GB[memoryIndex];
  }
  const hw = Object.assign({}, baseHW, { generation, coresPerSocket, sockets, cores, memoryGB });
  const row = evaluate(n, need, hw, wantResiliency);
  row.conservativeFit = row.fits && row.cpuUtilRounded < 90 && row.memUtilRounded < 90 && row.storageSizingUtilRounded < 90;
  row.hw = hw;
  return row;
}

function nearestSupportedCoreCount(generation, requested) {
  return generation.cores.reduce((nearest, cores) =>
    Math.abs(cores - requested) < Math.abs(nearest - requested) ? cores : nearest, generation.cores[0]);
}

function diskPlan(n, need, hw, factor) {
  const maxDisks = Math.min(40, Math.max(2, hw.maxDisks));
  const minimumDisks = 2;
  let sizeIndex = Math.max(0, DISK_TB.findIndex((size) => size >= hw.diskTB));
  if (sizeIndex < 0) sizeIndex = DISK_TB.length - 1;
  let diskGB = DISK_TB[sizeIndex] * 1024;
  let disks = Math.min(maxDisks, Math.max(minimumDisks, hw.autoDisks
    ? Math.ceil(((need.storageGB * factor + PLATFORM_VOLUMES_GB * factor + Math.min(n, 4) * diskGB) / n) / diskGB)
    : hw.diskCount));
  if (hw.autoDisks) {
    const threshold = Math.ceil(maxDisks * 0.5);
    if (disks >= threshold) {
      let consolidated = null;
      const rawPerNode = (need.storageGB * factor + PLATFORM_VOLUMES_GB * factor + Math.min(n, 4) * diskGB) / n;
      for (let i = sizeIndex + 1; i < DISK_TB.length; i++) {
        const candidateGB = DISK_TB[i] * 1024;
        const candidateDisks = Math.ceil(rawPerNode / candidateGB);
        if (candidateDisks < disks && candidateDisks <= maxDisks) {
          if (candidateDisks < threshold) {
            consolidated = { index: i, disks: candidateDisks };
            break;
          }
          if (!consolidated || candidateDisks < consolidated.disks) consolidated = { index: i, disks: candidateDisks };
        }
      }
      if (consolidated) {
        sizeIndex = consolidated.index;
        diskGB = DISK_TB[sizeIndex] * 1024;
        disks = consolidated.disks;
      }
    }
    for (let attempt = 0; attempt < 50; attempt++) {
      const repairGB = Math.min(n, 4) * diskGB;
      const rawNeed = need.storageGB * factor + PLATFORM_VOLUMES_GB * factor + repairGB;
      const rawCapacity = n * disks * diskGB;
      if (rawCapacity > 0 && rawNeed / rawCapacity <= STORAGE_HEADROOM) break;
      if (disks < maxDisks) {
        disks++;
      } else if (sizeIndex < DISK_TB.length - 1) {
        sizeIndex++;
        diskGB = DISK_TB[sizeIndex] * 1024;
        const rawPerNode = (need.storageGB * factor + PLATFORM_VOLUMES_GB * factor + Math.min(n, 4) * diskGB) / n;
        disks = Math.min(maxDisks, Math.max(minimumDisks, Math.ceil(rawPerNode / diskGB)));
      } else {
        break;
      }
    }
  }
  return { disks, diskTB: DISK_TB[sizeIndex], diskGB };
}

function evaluate(n, need, hw, wantResiliency) {
  const res = n < 3 ? 0 : wantResiliency;
  const factor = res === 0 ? 2 : 3;
  const effectiveNodes = n > 1 ? n - 1 : 1;
  const hostCores = Math.max(2, Math.ceil(hw.cores * 0.1));
  const hostMemoryGB = Math.max(HOST_MEMORY_BASE_GB, Math.ceil(hw.memoryGB * 0.08));
  const cpuCap = Math.max(0, (hw.cores - hostCores) * effectiveNodes * hw.ratio - ARB_VCPU);
  const memCap = Math.max(0, (hw.memoryGB - hostMemoryGB) * effectiveNodes - ARB_MEMORY_GB);
  const storage = diskPlan(n, need, hw, factor);
  const reserveDisks = Math.min(n, 4);
  const stoCap = Math.max((n * storage.disks - reserveDisks) * storage.diskGB / factor - PLATFORM_VOLUMES_GB, 0);
  const rawStorageNeed = need.storageGB * factor + PLATFORM_VOLUMES_GB * factor + reserveDisks * storage.diskGB;
  const rawStorageCapacity = n * storage.disks * storage.diskGB;
  const r = {
    n, cpuCap, memCap, stoCap, disks: storage.disks, diskTB: storage.diskTB, diskGB: storage.diskGB,
    hostCores, hostMemoryGB,
    cpuUtil: cpuCap ? need.vcpu / cpuCap : 9.99,
    memUtil: memCap ? need.memoryGB / memCap : 9.99,
    stoUtil: stoCap ? need.storageGB / stoCap : 9.99,
    cpuUtilRounded: Math.round((cpuCap ? need.vcpu / cpuCap : 9.99) * 100),
    memUtilRounded: Math.round((memCap ? need.memoryGB / memCap : 9.99) * 100),
    stoUtilRounded: Math.round((stoCap ? need.storageGB / stoCap : 9.99) * 100),
    storageSizingUtilRounded: Math.round((rawStorageCapacity ? rawStorageNeed / rawStorageCapacity : 9.99) * 100),
    resiliencyLabel: res === 0 ? "Two-way" : "Three-way",
  };
  r.limits = [];
  if (r.cpuUtil > 1) r.limits.push("CPU");
  if (r.memUtil > 1) r.limits.push("Memory");
  if (r.stoUtil > 1) r.limits.push("Storage");
  r.fits = r.limits.length === 0;
  r.conservativeFit = r.fits && r.cpuUtilRounded < 90 && r.memUtilRounded < 90 && r.storageSizingUtilRounded < 90;
  return r;
}

// The configuration object ODIN's Sizer reads from its ?config= parameter (field names match a known-good ODIN link).
function buildConfig(name, nodes, nodeUserSet, params, hw, res, demands, need, perVm) {
  const growth = 1 + (GROWTH_PCT[params.growth] ?? 10) / 100;
  const workloads = perVm
    ? demands.map((d, i) => ({ id: i + 1, type: "vm", name: d.vm.name, inputMode: "total", vcpus: Math.max(1, Math.ceil(d.vcpu * growth)), memory: Math.max(1, Math.ceil(d.memoryGB * growth)), storage: Math.max(1, Math.ceil(d.storageGB * growth)), count: 1, gpuMode: "none" }))
    : [{ id: 1, type: "vm", name: "RVTools selected VMs", inputMode: "total", vcpus: need.vcpu, memory: need.memoryGB, storage: need.storageGB, count: 1, gpuMode: "none" }];
  // Growth is already folded into the totals above, so ODIN's own growth is left at 0 to avoid double counting.
  return {
    clusterType: "standard", clusterName: name,
    disaggRackCount: "2", disaggStorageType: "fc_san", disaggSpineCount: 2,
    nodeCount: String(nodes), nodeCountUserSet: nodeUserSet,
    futureGrowth: "0", sizeFor5YrGrowth: false,
    resiliency: RESILIENCY[nodes < 3 ? 0 : res],
    cpuManufacturer: hw.generation.manufacturer, cpuGeneration: hw.generation.id,
    cpuCores: String(hw.coresPerSocket), cpuSockets: String(hw.sockets), cpuConfigUserSet: true,
    nodeMemory: String(hw.memoryGB), memoryUserSet: true,
    gpuCount: "0", gpuType: "a2",
    vcpuRatio: String(hw.ratio), vcpuRatioUserSet: true,
    storageConfig: "all-flash", storageTiering: "ssd-capacity",
    capacityDiskCount: String(hw.diskCount), capacityDiskSize: String(hw.diskTB),
    cacheDiskCount: "2", cacheDiskSize: "1.92",
    tieredCapacityDiskCount: "4", tieredCapacityDiskSize: "3.84",
    diskSizeUserSet: true, diskCountUserSet: true,
    repairDiskCount: String(Math.min(nodes, 4)), repairDisksUserSet: false,
    workloads, workloadIdCounter: workloads.length, instanceCount: "1",
    powerPriceInput: "", multiPowerPriceInput: "",
    importedProcessorName: null, importedCoresPerSocket: null,
    autoScaledFields: nodeUserSet ? [] : ["node-count"],
    disaggAutoUpgraded: false, _shareName: name,
  };
}

function odinUrl(config) {
  return ODIN_SIZER + "?config=" + encodeURIComponent(base64(JSON.stringify(config)));
}

// btoa isn't guaranteed in the script runtime, so encode by hand (UTF-8 safe).
function base64(text) {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const bytes = unescape(encodeURIComponent(text));
  let out = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes.charCodeAt(i), b = bytes.charCodeAt(i + 1), c = bytes.charCodeAt(i + 2);
    out += chars[a >> 2] + chars[((a & 3) << 4) | ((b || 0) >> 4)];
    out += isNaN(b) ? "=" : chars[((b & 15) << 2) | ((c || 0) >> 6)];
    out += isNaN(c) ? "=" : chars[c & 63];
  }
  return out;
}
