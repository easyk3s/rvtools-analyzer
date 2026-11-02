import Foundation

/// Sizes the selected VMs on vSphere 8, VVF 9 and VCF 9 and on alternate hypervisors (Hyper-V, Nutanix AHV, KVM such as
/// Proxmox VE, OpenShift Virtualization) with the same host model and failure rules, then breaks down where each platform's
/// extra hosts come from: management components, memory overcommit and tiering, per-host overhead, per-VM overhead and
/// control plane, and cluster size limits. VVF and VCF management components come from `VCFAppliances`.
/// Every platform figure is an assumption whose help text names its source; confirm them against current vendor docs.
public struct AlternateHypervisors: Solution {
    public init() {}
    public var id: String { "althv" }
    public var title: String { "Alternate Hypervisors" }
    public var symbol: String { "arrow.left.arrow.right.square" }
    public var summary: String { "Hosts needed on Hyper-V, Nutanix AHV, KVM (Proxmox VE, Scale HyperCore, VergeOS) and OpenShift Virtualization compared with vSphere, and why." }

    enum Platform: Int, CaseIterable {
        case vsphere8, vvf, vcf, hyperv, ahv, kvm, openshift
        /// Assumption prefix; the VMware editions share the vSphere host assumptions.
        var key: String { ["vs", "vs", "vs", "hv", "ahv", "px", "ocp"][rawValue] }
        var id: String { ["vs8", "vvf", "vcf", "hv", "ahv", "px", "ocp"][rawValue] }
        var name: String {
            ["vSphere 8", "VMware vSphere Foundation 9", "VMware Cloud Foundation 9", "Microsoft Hyper-V", "Nutanix AHV", "KVM (Proxmox VE, Scale HyperCore, VergeOS)",
             "OpenShift Virtualization"][rawValue]
        }
        var short: String { ["vSphere 8", "VVF 9", "VCF 9", "Hyper-V", "AHV", "KVM", "OpenShift"][rawValue] }
        var isVMware: Bool { rawValue <= Platform.vcf.rawValue }
        /// In the order of the "baseline" choice.
        static let editions: [Platform] = [.vcf, .vvf, .vsphere8]
        static let alternates: [Platform] = [.hyperv, .ahv, .kvm, .openshift]
    }

    public var parameters: [SolutionParameter] { [
        .multi("platforms", "Compare", "Platforms to compare with vSphere", Platform.alternates.map(\.name), selected: [0, 1, 2, 3]),
        .choice("baseline", "Compare", "Compare them with", Platform.editions.map(\.name),
                help: "vSphere 8, VVF 9 and VCF 9 are all sized; the comparison and the breakdown use this one."),
        .host("hostModel", "Target hosts", "Size new hosts like", none: "Typical host (median of the hosts behind the selected VMs)",
                help: "The same host model is used for every platform. Pick one of the export's hosts, or set cores and memory below."),
        .number("hostCores", "Target hosts", "Cores per host", 0, min: 0, max: 512,
                help: "Physical cores in each new host. 0 uses the host chosen above."),
        .number("hostRAM", "Target hosts", "Memory per host", 0, min: 0, max: 16_384, step: 64, unit: "GiB",
                help: "DRAM in each new host. 0 uses the host chosen above."),
        .choice("basis", "Capacity", "Size workloads from", ["Configured vCPU and memory", "Measured CPU and consumed memory"],
                help: "The same basis is used for every platform. Measured uses each VM's CPU (MHz) over the host clock and its consumed memory, falling back to configured sizes when the export doesn't have them."),
        .choice("ratioMode", "Capacity", "vCPU per core", ["Fixed ratio (below)", "Today's ratio, per source cluster"],
                help: "Today's ratio is each source cluster's powered-on vCPUs over its hosts' cores, kept between 1:1 and 15:1, as the Nutanix Sizer imports RVTools by default. It keeps today's consolidation on every platform."),
        .number("cpuRatio", "Capacity", "vCPU per core (configured sizes)", 4, min: 0.5, max: 20, step: 0.5, unit: ": 1",
                help: "The same on every platform: no vendor publishes a hard limit, so change it per run if you have evidence. VMware: no common ratio; start at 1:1 if you can't react to contention quickly (VCF blog, \"vCPU to pCPU ratio guidelines\", June 2025). Nutanix: 1:1 to 2:1 for business-critical or latency-sensitive VMs, up to 4:1 for the rest (Nutanix, \"Understanding CPU resource management in Nutanix AHV\"). Hyper-V: no ratio imposed (Microsoft, Hyper-V maximum scale limits); Windows Server 2008 R2 supported 8:1 per logical processor, 12:1 for VDI. KVM: older Red Hat guidance says no more than 10 vCPUs per physical core (RHEL 6 Virtualization Administration Guide). OpenShift Virtualization's CPU allocation ratio (default 10:1) is a scheduling request, not a planning ratio; Red Hat's sizing guide plans with a separate ratio, 4:1 in its example. No independent test compares the CPU schedulers; Principled Technologies' Broadcom-commissioned vSphere 8 vs OpenShift density study tested memory overcommit."),
        .number("htCredit", "Capacity", "Hyperthreading credit per extra thread", 0, min: 0, max: 50, step: 5, unit: "%",
                help: "Counts each extra hardware thread as this share of a core, the same on every platform: a 64-core, 128-thread host at 25% counts as 80 cores. 0 sizes on physical cores. Red Hat's OpenShift Virtualization sizing guide uses 25% and suggests 10–15% conservative, 20–30% moderate, 35–45% aggressive."),
        .number("cpuSpeed", "Capacity", "Per-core performance of the new hosts vs today", 1, min: 0.25, max: 4, step: 0.05, unit: "×",
                help: "Divides the workloads' CPU need, the same on every platform. 1 sizes on today's CPUs. The Nutanix Sizer does this with SPECint rate per core: a Xeon Gold 6338 is 6.66 per core and current Xeon 6 and EPYC 9005 parts about 12.5, so about 1.9×. Use it with a host model that has the new hosts' cores."),
        .choice("clusterMode", "Capacity", "Clusters", ["One pool (greenfield)", "Keep today's clusters"],
                help: "Keep today's clusters sizes each source cluster's VMs as their own cluster, with its own minimum size and spare hosts, as the Nutanix Sizer does when it retains the VM-to-cluster mapping. Standalone hosts become a cluster too. Management components go in the largest cluster, or their own cluster where that's chosen."),
        .number("spare", "Capacity", "Host failures to tolerate per cluster", 1, min: 0, max: 3),
        .choice("include", "Capacity", "VMs to size", ["Powered on and suspended", "All VMs, powered off too", "Powered on only"],
                help: "Suspended VMs need their memory back when they resume, so they're sized with the running VMs. Including powered-off VMs reserves room to start every VM; with measured usage they're sized from their configuration. Storage always counts every selected VM."),
        .number("maxLoad", "Capacity", "Max CPU / memory load with those hosts down", 80, min: 50, max: 100, unit: "%"),
        .choice("storageBasis", "Storage", "Size storage from", ["In use (excluding swap)", "Provisioned"],
                help: "Every selected VM counts, powered off too. Provisioned is each VM's virtual disk capacity, as the Nutanix Sizer imports RVTools by default; in use is what the VMs occupy today, thin disks included."),
        .number("growth", "Storage", "Estimated growth", 10, min: 0, max: 200, unit: "%"),
        .number("reserve", "Storage", "Free-space reserve (rebuild and operations)", 30, min: 0, max: 80, unit: "%",
                help: "Kept free on every platform's storage for rebuilds after a host failure."),
        .number("mgmtRatio", "Capacity", "Management VMs — vCPU per core", 2, min: 0.5, max: 8, step: 0.5, unit: ": 1",
                help: "For every platform's management VMs (VCF and VVF appliances, Prism Central and so on). The VCF 9.1.1 Planning and Preparation Workbook recommends 2:1 for a performant management domain."),

        // VCF 9
        .choice("vcfArch", "VMware Cloud Foundation 9", "Management domain", [
            "Dedicated — its own cluster",
            "Consolidated — management runs in the workload cluster",
        ], help: "Dedicated is the VCF design ideal: the management domain gets its own cluster, with its own spare, and also runs the workload domain's vCenter and NSX Managers. It needs at least 4 hosts for a high-availability deployment, 3 for simple. Consolidated puts the management appliances in the workload cluster."),
        .choice("vcfDeploy", "VMware Cloud Foundation 9", "Deployment model", VCFAppliances.Deployment.allCases.map { d in
            d.isHA ? "High availability — \(d.size)" : "Simple — single-node appliances (Small)"
        }, selected: 1, help: "Sets appliance sizes and node counts as the VCF Installer does. Sizes come from the \(VCFAppliances.source), as in VCF 9 Sizing."),
        .toggle("vcfOps", "VMware Cloud Foundation 9", "VCF Operations (with cloud proxy and license server)", true,
                help: "VCF 9 uses VCF Operations for licensing and fleet management. The SDDC Manager, management vCenter, NSX Managers and VCF services runtime are always counted."),

        // VVF 9
        .choice("vvfArch", "VMware vSphere Foundation 9", "Management components", [
            "Consolidated — in the workload cluster",
            "Dedicated management cluster",
        ], help: "VVF's smaller footprint usually runs in the workload cluster; a dedicated cluster is still worth it when hosts can be spared."),
        .toggle("vvfServices", "VMware vSphere Foundation 9", "VCF management services", true,
                help: "Fleet and SDDC lifecycle, software depot and telemetry on the VCF services runtime, as the VCF Installer deploys VVF (simple mode). Without them VVF is installed by hand: vCenter, VCF Operations and license server."),
        .choice("vvfVC", "VMware vSphere Foundation 9", "vCenter", ["Existing vCenter (converge)", "New vCenter (Medium)"],
                help: "Converging keeps the vCenter that runs the clusters today, so it isn't counted; a new deployment adds a Medium vCenter, the VCF Installer's VVF default. VCF Operations (Medium, one node) and the license server are always counted."),

        // vSphere 8
        .toggle("vs8VC", "vSphere 8", "Count a new vCenter (Medium)", false,
                help: "Off assumes the existing vCenter keeps running where it is. vSphere 8 needs nothing else for management."),

        // Memory tiering (VVF 9 and VCF 9)
        .toggle("vsTier", "Memory tiering (VVF 9 and VCF 9)", "NVMe memory tiering", false,
                help: "Uses NVMe devices as a second memory tier. GA in VCF 9.0 and VVF 9.0; vSphere 8.0 U3 had it only as a tech preview, so it never applies to vSphere 8. Off by default: every host needs an NVMe device for it (two to mirror it in 9.1), and it suits workloads whose active memory fits in DRAM. Sources: Broadcom VCF blog, \"Advanced Memory Tiering now available\" and \"Smarter infrastructure starts here\" (June 2025)."),
        .number("vsTierRatio", "Memory tiering (VVF 9 and VCF 9)", "NVMe tier size, as a share of DRAM", 100, min: 0, max: 400, step: 25, unit: "%",
                help: "VCF 9.0 defaults to a 1:1 DRAM:NVMe ratio, doubling memory. Broadcom quotes up to 4x with other ratios, depending on how active the workloads are. Active memory must still fit in DRAM, which this sizing checks when the export has active memory. Source: Broadcom VCF blog (June 2025)."),
        .number("vsMem", "vSphere (all editions)", "Memory overcommit (VM memory per host memory)", 100, min: 100, max: 300, step: 5, unit: "%",
                help: "Beyond tiering: ballooning, compression and page sharing. 100% sizes VM memory 1:1, the usual design rule."),
        .number("vsCores", "vSphere (all editions)", "Per-host overhead — cores", 0, min: 0, max: 64,
                help: "ESXi and vSAN ESA CPU use is not reserved; 0 by default."),
        .number("vsRAM", "vSphere (all editions)", "Per-host overhead — memory", 16, min: 0, max: 512, unit: "GiB",
                help: "ESXi plus vSAN ESA memory. An estimate: vSAN memory grows with the number of disks; see Broadcom's \"vSAN memory consumption\" KB for your host."),
        .number("vsMax", "vSphere (all editions)", "Hosts per cluster, at most", 64, min: 2, max: 96,
                help: "vSAN clusters go to 64 hosts (Broadcom KB 327030, \"Creating vSAN clusters up to 64 nodes\"). Plain vSphere clusters go higher; see configmax.broadcom.com."),
        .number("vsMin", "vSphere (all editions)", "Hosts per cluster, at least", 3, min: 1, max: 8, help: "vSAN needs 3 hosts (2 with a witness)."),
        .number("vsRawTB", "vSphere (all editions)", "Raw capacity per host (vSAN)", 0, min: 0, max: 2000, step: 1, unit: "TB",
                help: "Raw drive capacity in each host. With a value, hosts are added until the raw storage the platform needs (with its protection and the free-space reserve) fits; 0 leaves storage out of the host count. Ignored with external storage."),
        .choice("vsStorage", "vSphere (all editions)", "vSAN ESA storage policy", ["RAID-5 adaptive (2+1 under 6 hosts, 4+1 at 6+)", "RAID-6 (4+2)", "RAID-1 mirror", "External storage"],
                help: "RAID-5 2+1 stores 150% of the data, 4+1 stores 125%; RAID-6 4+2 stores 150%; RAID-1 stores 200%. Source: Duncan Epping, \"vSAN 8.0 ESA – Introducing Adaptive RAID-5\" (Yellow Bricks), and Broadcom KB 405876."),

        // Hyper-V
        .number("hvMem", "Microsoft Hyper-V", "Memory overcommit (VM memory per host memory)", 100, min: 100, max: 300, step: 5, unit: "%",
                help: "Dynamic Memory hot-adds and balloons memory per VM. It works best with Windows guests; Linux support depends on the distribution and kernel. 100% sizes VM memory 1:1. Source: Microsoft Learn, \"Hyper-V Dynamic Memory Overview\"."),
        .number("hvCores", "Microsoft Hyper-V", "Per-host overhead — cores", 2, min: 0, max: 64,
                help: "Management OS (parent partition), failover clustering and Storage Spaces Direct. An estimate; Microsoft doesn't publish a fixed figure."),
        .number("hvRAM", "Microsoft Hyper-V", "Per-host overhead — memory", 8, min: 0, max: 512, unit: "GiB",
                help: "Hyper-V calculates and keeps a host reserve for the management OS and cluster services (Microsoft Learn, \"Hyper-V Dynamic Memory Overview\"); 8 GiB is an estimate."),
        .number("hvCacheTB", "Microsoft Hyper-V", "Storage Spaces Direct cache drives per host", 0, min: 0, max: 100, step: 0.5, unit: "TB",
                help: "S2D needs 4 GB of memory per TB of cache drive on each server, on top of the host and VMs. All-NVMe hosts with one drive type have no cache tier. Source: Microsoft Learn, \"Storage Spaces Direct hardware requirements\"."),
        .number("hvMax", "Microsoft Hyper-V", "Hosts per cluster, at most", 16, min: 2, max: 64,
                help: "Storage Spaces Direct supports 2 to 16 servers (Microsoft Learn, \"Storage Spaces Direct hardware requirements\"). With SAN storage instead, failover clusters go to 64 nodes (Microsoft Learn, \"Hyper-V maximum scale limits\", Windows Server 2025)."),
        .number("hvClusterVMs", "Microsoft Hyper-V", "Running VMs per cluster, at most", 8000, min: 100, max: 8000, step: 100,
                help: "A failover cluster runs up to 8,000 VMs; more VMs need another cluster, with its own spare host. Source: Microsoft Learn, \"Hyper-V maximum scale limits\" (Windows Server 2025)."),
        .number("hvHostVMs", "Microsoft Hyper-V", "Running VMs per host, at most", 1024, min: 10, max: 1024, step: 8,
                help: "Hyper-V runs up to 1,024 VMs per server; checked with the failover hosts down. Source: Microsoft Learn, \"Hyper-V maximum scale limits\" (Windows Server 2025)."),
        .number("hvHostVCPU", "Microsoft Hyper-V", "Virtual processors in use per host, at most", 2048, min: 64, max: 2048, step: 64,
                help: "Hyper-V allows 2,048 virtual processors in use per host, with no ratio to logical processors imposed; checked with the failover hosts down. Source: Microsoft Learn, \"Hyper-V maximum scale limits\" (Windows Server 2025)."),
        .number("hvMin", "Microsoft Hyper-V", "Hosts per cluster, at least", 2, min: 1, max: 8, help: "S2D needs 2 servers."),
        .number("hvRawTB", "Microsoft Hyper-V", "Raw capacity per host", 0, min: 0, max: 2000, step: 1, unit: "TB",
                help: "Raw drive capacity in each host. With a value, hosts are added until the raw storage the platform needs (with its protection and the free-space reserve) fits; 0 leaves storage out of the host count. Ignored with external storage."),
        .number("hvStorage", "Microsoft Hyper-V", "Raw storage per usable (0 = external array)", 3, min: 0, max: 4, step: 0.05, unit: "×",
                help: "Three-way mirror, needed to survive two failures, keeps 33% of raw capacity: 3×. Two-way mirror is 2×; mirror-accelerated parity falls in between. Source: Microsoft Learn, \"Fault tolerance and storage efficiency\"."),
        .toggle("hvVMM", "Microsoft Hyper-V", "System Center Virtual Machine Manager", true,
                help: "Hyper-V's counterpart to vCenter for managing many hosts and clusters: the VMM server and its SQL Server database, as VMs in the workload cluster, 4 vCPU, 16 GiB each. These sizes are an estimate: Microsoft's VMM 2025 documentation gives only a 4 GB minimum startup memory for a VMM VM. Turn it off for Windows Admin Center or Failover Cluster Manager alone."),
        .number("hvMgmtCPU", "Microsoft Hyper-V", "Other management VMs — vCPU", 0, min: 0, max: 500,
                help: "System Center VMM, Windows Admin Center or other management VMs, if used; they run in the workload cluster. 0 by default."),
        .number("hvMgmtRAM", "Microsoft Hyper-V", "Other management VMs — memory", 0, min: 0, max: 4000, step: 4, unit: "GiB"),

        // Nutanix AHV
        .number("ahvMem", "Nutanix AHV", "Memory overcommit (VM memory per host memory)", 100, min: 100, max: 300, step: 5, unit: "%",
                help: "AHV memory overcommit (AOS 6.1 and later) is enabled per VM, uses ballooning and host swap, and Nutanix suggests starting with non-production VMs. 100% sizes VM memory 1:1. Source: Nutanix, \"AHV Internals: Memory Overcommit\"."),
        .number("ahvCores", "Nutanix AHV", "Per-host overhead — cores (Controller VM)", 5, min: 0, max: 64,
                help: "Every node runs a Controller VM (CVM) for storage; Foundation sizes it by platform. Source: Nutanix Sizer 6.0.13 (AOS 7.6) on a 16-node, 4-cluster sample: 76 physical cores and 896 GiB of CVM overhead, about 4.75 cores and 56 GiB per node, averaged across node models. See also the CVM Field Specifications for your AOS version."),
        .number("ahvRAM", "Nutanix AHV", "Per-host overhead — memory (Controller VM and AHV)", 56, min: 0, max: 512, unit: "GiB",
                help: "CVM memory grows with features (deduplication, RF3, Nutanix Files) and node size; older guidance was a 32 GB minimum. Source: Nutanix Sizer 6.0.13 (AOS 7.6) on a 16-node, 4-cluster sample: 76 physical cores and 896 GiB of CVM overhead, about 4.75 cores and 56 GiB per node, averaged across node models; Nutanix Prism \"CVM Memory Configuration\"."),
        .number("ahvMax", "Nutanix AHV", "Hosts per cluster, at most", 32, min: 3, max: 64,
                help: "32 nodes for AHV per Nutanix's Configuration Maximums as quoted on the Nutanix community (2023); check the portal for your AOS version."),
        .number("ahvMin", "Nutanix AHV", "Hosts per cluster, at least", 3, min: 1, max: 8, help: "RF2 clusters need 3 nodes."),
        .number("ahvRawTB", "Nutanix AHV", "Raw capacity per host", 0, min: 0, max: 2000, step: 1, unit: "TB",
                help: "Raw drive capacity in each host. With a value, hosts are added until the raw storage the platform needs (with its protection and the free-space reserve) fits; 0 leaves storage out of the host count. Ignored with external storage."),
        .number("ahvStorage", "Nutanix AHV", "Raw storage per usable (0 = external array)", 2, min: 0, max: 4, step: 0.05, unit: "×",
                help: "RF2 keeps two copies: 2×. RF3 is 3×. Erasure coding (EC-X) lowers this for cold data only."),
        .choice("ahvPC", "Nutanix AHV", "Prism Central", [
            "Automatic — X-Small up to 50 hosts and 500 VMs, otherwise Small",
            "X-Small (4 vCPU, 18 GB)", "Small (6 vCPU, 26 GB)", "Large (10 vCPU, 44 GB)", "X-Large (14 vCPU, 60 GB)",
            "Custom (below)", "None",
        ], help: "Prism Central is needed for multi-cluster management, DR and most add-ons; it runs in the workload cluster. The Nutanix Sizer adds an X-Small one automatically. X-Small (4 vCPU, 18 GB) manages up to 5 clusters, 50 hosts and 500 VMs (Nutanix, \"Introducing X-Small Prism Central\"). Small, Large and X-Large sizes as documented by OVHcloud's Nutanix service; confirm in Nutanix KB-16847. Scale-out deploys three VMs."),
        .number("ahvMgmtCPU", "Nutanix AHV", "Custom management VMs — vCPU", 6, min: 0, max: 500,
                help: "Used when Prism Central is set to Custom: Prism Central and any other management VMs."),
        .number("ahvMgmtRAM", "Nutanix AHV", "Custom management VMs — memory", 26, min: 0, max: 4000, step: 2, unit: "GiB"),

        // KVM: generic, Proxmox VE, Scale Computing HyperCore or VergeOS
        .choice("kvmFlavor", "KVM", "KVM platform", AlternateHypervisors.kvmFlavors, selected: 1,
                help: "Sets how the KVM platform is sized: generic KVM and Proxmox VE with Ceph (the settings below), Scale Computing HyperCore or VergeOS (their own settings). Proxmox VE also counts Proxmox Datacenter Manager."),
        .number("pxMem", "KVM", "Memory overcommit (VM memory per host memory)", 100, min: 100, max: 300, step: 5, unit: "%",
                help: "KVM ballooning and KSM page merging. Proxmox warns that aggressive ballooning can trigger the guest's OOM killer, and KSM costs CPU. 100% sizes VM memory 1:1. VergeOS is always 1:1: it doesn't balloon and says to avoid overcommitting RAM (VergeOS docs, \"Guest memory management\"). Source: Proxmox VE wiki, \"Dynamic Memory Management\"."),
        .number("pxRawTB", "KVM", "Raw capacity per host", 0, min: 0, max: 2000, step: 1, unit: "TB",
                help: "Raw drive capacity in each host. With a value, hosts are added until the raw storage the platform needs (with its protection and the free-space reserve) fits; 0 leaves storage out of the host count. Ignored with external storage."),
        .number("pxMgmtCPU", "KVM", "Other management VMs — vCPU", 0, min: 0, max: 500,
                help: "Backup servers or other management VMs, in the workload cluster. Proxmox Datacenter Manager is counted separately."),
        .number("pxMgmtRAM", "KVM", "Other management VMs — memory", 0, min: 0, max: 4000, step: 4, unit: "GiB"),
        .number("pxCores", "KVM — Generic and Proxmox VE (Ceph)", "Per-host overhead — cores (host)", 1, min: 0, max: 64, help: "The KVM host before Ceph. An estimate."),
        .number("pxRAM", "KVM — Generic and Proxmox VE (Ceph)", "Per-host overhead — memory (host)", 4, min: 0, max: 512, unit: "GiB",
                help: "The KVM host before Ceph. Proxmox VE recommends at least 2 GB for the OS and its services, plus about 1 GB per TB of used storage with ZFS (Proxmox VE docs, \"System Requirements\")."),
        .number("pxOSDs", "KVM — Generic and Proxmox VE (Ceph)", "Ceph OSDs (NVMe drives) per host", 4, min: 0, max: 32,
                help: "0 for external storage. Each OSD adds the cores and memory below; Ceph also needs 3 monitors and managers."),
        .number("pxOSDCores", "KVM — Generic and Proxmox VE (Ceph)", "Cores per Ceph OSD", 2, min: 0, max: 8, step: 0.5,
                help: "Proxmox suggests 4 to 6 CPU threads per NVMe OSD for high-performance disks, about 2 to 3 cores with hyperthreading. Source: Proxmox VE docs, \"Deploy Hyper-Converged Ceph Cluster\"."),
        .number("pxOSDRAM", "KVM — Generic and Proxmox VE (Ceph)", "Memory per Ceph OSD", 8, min: 1, max: 32, unit: "GiB",
                help: "Proxmox recommends at least 8 GiB per OSD daemon (the default target is 4 GiB; the rest covers recovery and backfill). Source: Proxmox VE docs, \"Deploy Hyper-Converged Ceph Cluster\"."),
        .number("pxCephSvcCores", "KVM — Generic and Proxmox VE (Ceph)", "Ceph monitor and manager cores, per cluster", 6, min: 0, max: 32,
                help: "Proxmox's rule of thumb is at least one core per Ceph service, and Ceph needs 3 monitors with a manager on each: 6 cores. Counted once per cluster when there are OSDs. Source: Proxmox VE docs, \"Deploy Hyper-Converged Ceph Cluster\"."),
        .number("pxMax", "KVM — Generic and Proxmox VE (Ceph)", "Hosts per cluster, at most", 32, min: 3, max: 64,
                help: "Proxmox VE sets no explicit node limit and reports production clusters over 50 nodes on high-end hardware; corosync needs under 5 ms latency, ideally on a dedicated network. 32 is a practical default. Source: Proxmox VE docs, \"Cluster Manager\"."),
        .number("pxMin", "KVM — Generic and Proxmox VE (Ceph)", "Hosts per cluster, at least", 3, min: 1, max: 8, help: "Ceph needs 3 nodes, and so does HA quorum (Proxmox VE docs)."),
        .number("pxStorage", "KVM — Generic and Proxmox VE (Ceph)", "Raw storage per usable (0 = external array)", 3, min: 0, max: 4, step: 0.05, unit: "×",
                help: "Ceph pools default to 3 replicas (size 3, min_size 2): 3×. Erasure-coded pools (e.g. 4+2 at 1.5×) are rarely used for VM disks. Source: Proxmox VE docs, \"Deploy Hyper-Converged Ceph Cluster\"."),
        .toggle("pxPDM", "KVM — Generic and Proxmox VE (Ceph)", "Proxmox Datacenter Manager (Proxmox VE)", true,
                help: "Multi-cluster management, one VM in the workload cluster. Production minimum: 2 cores, 4 GiB and 40 GB. Source: Proxmox Datacenter Manager 1.1 docs, \"System Requirements\"."),
        .number("scCores", "KVM — Scale Computing HyperCore", "Per-host overhead — cores", 2, min: 0, max: 64,
                help: "HyperCore's SCRIBE storage runs in the kernel beside the hypervisor, not in a controller VM. Scale doesn't publish the reservation: an estimate."),
        .number("scRAM", "KVM — Scale Computing HyperCore", "Per-host overhead — memory", 8, min: 0, max: 512, unit: "GiB",
                help: "Scale doesn't publish how much memory HyperCore reserves per node: an estimate. Confirm with Scale Computing."),
        .number("scMax", "KVM — Scale Computing HyperCore", "Hosts per cluster, at most", 8, min: 1, max: 64,
                help: "Clusters scale to eight nodes; larger clusters need Scale Computing's involvement. Sources: SC//HyperCore data sheet; Scale HC3 product specifications."),
        .number("scMin", "KVM — Scale Computing HyperCore", "Hosts per cluster, at least", 3, min: 1, max: 8,
                help: "Three nodes for a highly available cluster; single-node edge systems are also supported."),
        .number("scStorage", "KVM — Scale Computing HyperCore", "Raw storage per usable", 2, min: 1, max: 4, step: 0.05, unit: "×",
                help: "SCRIBE writes two or more copies of every chunk, equivalent to RAID 10: 2×. Deduplication isn't counted. Source: Scale Computing, \"SCRIBE block engine\"."),
        .choice("vgRedundancy", "KVM — VergeOS", "vSAN redundancy", ["N+1 — 2 copies", "N+2 — 3 copies"],
                help: "N+1 keeps 2 copies (about 2× raw, 2 controller nodes); N+2 keeps 3 (about 3×, 3 controller nodes, 5 recommended). Deduplication isn't counted. Source: VergeOS docs, \"vSAN redundancy levels\"."),
        .number("vgDisks", "KVM — VergeOS", "Storage disks per host", 4, min: 0, max: 32,
                help: "VergeOS needs 1 physical core per storage disk (hardware threads don't count). Source: VergeOS docs, \"Sizing\"."),
        .number("vgRawTB", "KVM — VergeOS", "Raw storage per host, for the memory reserve", 30, min: 0, max: 2000, step: 1, unit: "TB",
                help: "VergeOS reserves 16 GB plus 1 GB per TB of raw storage on each node, before guest memory. Uses Raw capacity per host above when that's set. Source: VergeOS docs, \"Sizing\"."),
        .number("vgMax", "KVM — VergeOS", "Hosts per cluster, at most", 200, min: 2, max: 200,
                help: "VergeOS 4.12 supports 200 nodes per system across up to 100 clusters, with no per-cluster limit listed. Source: VergeOS docs, \"Hardware requirements\"."),

        // OpenShift Virtualization
        .number("ocpMem", "OpenShift Virtualization", "Memory overcommit (VM memory per host memory)", 100, min: 100, max: 400, step: 25, unit: "%",
                help: "memoryOvercommitPercentage: VMs reserve their full memory at 100%; 200% counts half of each VM's memory, a 2:1 ratio. It needs swap on every node and the wasp agent (OpenShift 4.17 and later); without swap Red Hat strongly discourages it. KSM and free page reporting aren't counted. Red Hat suggests planning from today's ratio, VM memory over host memory in use, shown in the results. Source: Red Hat, \"OpenShift Virtualization Cluster Sizing Guide\" v3.1.0 (June 2026)."),
        .number("ocpCores", "OpenShift Virtualization", "Extra per-host overhead — cores", 0, min: 0, max: 64,
                help: "On top of what Red Hat's formula reserves on every node: kubelet system and kube reserved (CPU 0.06 + 0.012 per effective core after the first, at least 0.5) plus OpenShift Virtualization's fixed 2 cores and 360 MiB. Source: Red Hat, \"OpenShift Virtualization Cluster Sizing Guide\" v3.1.0 (June 2026); Red Hat KCS 5843241."),
        .number("ocpRAM", "OpenShift Virtualization", "Extra per-host overhead — memory", 0, min: 0, max: 512, unit: "GiB",
                help: "On top of Red Hat's formula: kube reserved memory is 25% of the first 4 GiB, 20% of the next 4, 10% of the next 8, 6% up to 128 GiB and 2% above, plus 360 MiB for OpenShift Virtualization. Source: Red Hat, \"OpenShift Virtualization Cluster Sizing Guide\" v3.1.0 (June 2026); Red Hat KCS 5843241."),
        .number("ocpDrives", "OpenShift Virtualization", "OpenShift Data Foundation drives per host", 4, min: 0, max: 24,
                help: "0 for external storage. ODF comes with OpenShift Platform Plus but not with OpenShift Virtualization Engine (OVE), which often uses external storage or adds ODF as a separate purchase. ODF internal mode needs 30 CPU and 72 GiB across 3 nodes for the first 3 drives, plus 6 CPU and 15 GiB per further 3 drives; per node that is 10 logical CPUs and 24 GiB plus 2 logical CPUs and 5 GiB per drive after the first, counted here as half as many cores (hyperthreading). Source: Red Hat ODF 4.18, \"Planning your deployment — Resource requirements\"."),
        .number("ocpControl", "OpenShift Virtualization", "Control-plane nodes per cluster", 3, min: 0, max: 5,
                help: "Dedicated control-plane nodes (3, 4 or 5) don't run VMs. 0 for a hosted control plane, which runs on a separate management cluster and is Red Hat's recommendation with memory overcommit, or for a schedulable (compact) control plane, which isn't supported with memory overcommit. Source: Red Hat, \"OpenShift Virtualization Cluster Sizing Guide\" v3.1.0 (June 2026)."),
        .number("ocpHub", "OpenShift Virtualization", "Advanced Cluster Management hub nodes", 0, min: 0, max: 7,
                help: "Red Hat Advanced Cluster Management manages several OpenShift clusters (Advanced Cluster Management for Virtualization pairs with OpenShift Virtualization Engine) and runs on its own hub cluster, which can also host hosted control planes. 0 leaves it out; 3 adds a three-node hub. Red Hat publishes hub sizing by managed-cluster count in ACM's \"Sizing your hub cluster\"; size the hub from that."),
        .number("ocpMaxPods", "OpenShift Virtualization", "VMs per node, at most", 250, min: 10, max: 500, step: 10,
                help: "Each VM is a pod, and kubelet's maxPods defaults to 250; it can go to 500, beyond which kubelet and API server stability suffer. Checked with the failover nodes down. Source: Red Hat, \"OpenShift Virtualization Cluster Sizing Guide\" v3.1.0 (June 2026)."),
        .number("ocpInfraCores", "OpenShift Virtualization", "Infrastructure workloads per cluster — cores", 24, min: 0, max: 500,
                help: "Ingress, image registry, monitoring, logging and other cluster services, sharing the worker nodes. Red Hat's guide uses 24 cores and 128 GiB as an illustrative example, not a validated figure; size them from each component's documentation."),
        .number("ocpInfraRAM", "OpenShift Virtualization", "Infrastructure workloads per cluster — memory", 128, min: 0, max: 4000, step: 8, unit: "GiB"),
        .number("ocpMax", "OpenShift Virtualization", "Worker nodes per cluster, at most", 100, min: 3, max: 500,
                help: "OpenShift Virtualization was tested to 500 nodes; Red Hat recommends 100 or fewer and more clusters beyond that. Source: Red Hat, OpenShift Virtualization \"Supported limits\"."),
        .number("ocpMin", "OpenShift Virtualization", "Worker nodes per cluster, at least", 3, min: 1, max: 8, help: "ODF needs 3 nodes."),
        .number("ocpRawTB", "OpenShift Virtualization", "Raw capacity per host", 0, min: 0, max: 2000, step: 1, unit: "TB",
                help: "Raw drive capacity in each host. With a value, hosts are added until the raw storage the platform needs (with its protection and the free-space reserve) fits; 0 leaves storage out of the host count. Ignored with external storage."),
        .number("ocpStorage", "OpenShift Virtualization", "Raw storage per usable (0 = external array)", 3, min: 0, max: 4, step: 0.05, unit: "×",
                help: "ODF (Ceph) keeps 3 replicas: 3×."),
    ] }

    public func defaultSelection(_ inventory: Inventory) -> Set<String> {
        Set(inventory.workloadVMs.map(\.id))
    }


    // MARK: - Model

    typealias Component = VCF9Sizing.Component

    struct HostSpec {
        /// Effective cores: physical cores plus the hyperthreading credit.
        var cores: Double, ramGiB: Double, mhz: Double, name: String
        var physical = 0.0, threads = 0.0
    }

    /// Red Hat's per-node reservation for an OpenShift Virtualization worker: kubelet system and kube reserved (KCS 5843241)
    /// plus OpenShift Virtualization's fixed 2 cores and 360 MiB ("OpenShift Virtualization Cluster Sizing Guide" v3.1.0).
    static func openShiftNodeReserve(effectiveCores: Double, ramGiB: Double) -> (cores: Double, ramGiB: Double) {
        let cpu = max(0.5, 0.06 + 0.012 * (effectiveCores - 1))
        let tiers: [(size: Double, share: Double)] = [(4, 0.25), (4, 0.20), (8, 0.10), (112, 0.06), (.infinity, 0.02)]
        var left = ramGiB, ram = 0.0
        for t in tiers where left > 0 { let part = min(left, t.size); ram += part * t.share; left -= part }
        return (cpu + 2, ram + 360.0 / 1024)
    }

    struct Demand {
        var cores = 0.0, ramGiB = 0.0
        /// Active memory, which must stay in DRAM with tiering; nil when the export has none.
        var activeGiB: Double?
        /// VMs and configured vCPUs, for per-host and per-cluster limits.
        var vms = 0, vcpus = 0.0
        /// Usable storage, including the free-space reserve, for sizing hosts by storage.
        var usableMiB = 0.0
        var isEmpty: Bool { cores <= 0 && ramGiB <= 0 }
        static func + (a: Demand, b: Demand) -> Demand {
            Demand(cores: a.cores + b.cores, ramGiB: a.ramGiB + b.ramGiB, activeGiB: a.activeGiB.map { $0 + (b.activeGiB ?? 0) },
                   vms: a.vms + b.vms, vcpus: a.vcpus + b.vcpus, usableMiB: a.usableMiB + b.usableMiB)
        }
    }

    /// One platform's rules, from the assumptions.
    struct Profile {
        let platform: Platform
        var density = 1.0           // VM memory per host memory
        var tier = 0.0              // NVMe tier as a share of DRAM
        var hostCores = 0.0, hostRAM = 0.0
        var perVMOverhead = false   // OpenShift virt-launcher overhead
        var control = 0             // hosts per cluster that run no VMs
        var maxHosts = 64, minHosts = 3
        var storage: (Int) -> Double? = { _ in nil }   // raw per usable, given hosts per cluster; nil = external
        /// Management components, given the workload hosts and clusters they manage.
        var management: (Int, Int) -> [Component] = { _, _ in [] }
        /// Management in its own cluster (at least `mgmtMinHosts`), rather than in the workload cluster.
        var mgmtDedicated = false
        var mgmtMinHosts = 3
        /// Hard limits (0 = none): running VMs and in-use vCPUs per host, running VMs per cluster.
        var maxVMsPerHost = 0, maxVCPUPerHost = 0, maxVMsPerCluster = 0
        /// Raw drive capacity per host; 0 leaves storage out of the host count.
        var rawPerHostMiB = 0.0
        /// Cores and memory needed once per cluster outside the sized VMs (Ceph monitors and managers, OpenShift infra).
        var clusterCores = 0.0, clusterRAM = 0.0
        /// Hosts in a separate management cluster that isn't sized from demand (an OpenShift ACM hub).
        var fixedHosts = 0
    }

    struct Plan {
        var hosts = 0, clusters = 0, control = 0
        /// Hosts and clusters of a dedicated management cluster, included in `hosts` and `clusters`.
        var mgmtHosts = 0, mgmtClusters = 0
        var mgmt: [Component] = []
        /// Hosts (with control-plane nodes) per workload group, in group order.
        var groupHosts: [Int] = []
        var cpuLoad = 0.0, memLoad = 0.0, activeLoad = 0.0
        /// Shares of the hard limits and of the hosts' raw storage (1 = full).
        var vmLoad = 0.0, vcpuLoad = 0.0, storageLoad = 0.0
        var maxLoad = 1.0
        var feasible = true
        var total: Int { hosts + control }
        var load: Double { max(cpuLoad, memLoad, activeLoad) }
        var fits: Bool { load <= maxLoad && vmLoad <= 1 && vcpuLoad <= 1 && storageLoad <= 1 }
        var driver: String {
            if !feasible { return "Doesn't fit" }
            let r = maxLoad > 0 ? maxLoad : 1
            let limits: [(String, Double)] = [("CPU", cpuLoad / r), ("Memory", memLoad / r), ("Active memory (DRAM)", activeLoad / r),
                                              ("Storage", storageLoad), ("VMs per host", vmLoad), ("vCPUs per host", vcpuLoad)]
            return limits.max { $0.1 < $1.1 }!.0
        }
    }

    /// How the KVM platform is sized, with the short names used in results.
    static let kvmFlavors = ["Generic KVM", "Proxmox VE", "Scale Computing HyperCore", "VergeOS"]
    static let kvmShort = ["KVM", "Proxmox VE", "HyperCore", "VergeOS"]

    /// Prism Central single-VM sizes: X-Small from Nutanix ("Introducing X-Small Prism Central"), the others as documented by
    /// OVHcloud's Nutanix service (confirm in Nutanix KB-16847).
    static let prismCentral: [(name: String, cpu: Double, ram: Double, disk: Double)] = [
        ("X-Small", 4, 18, 100), ("Small", 6, 26, 500), ("Large", 10, 44, 2500), ("X-Large", 14, 60, 2500),
    ]

    /// OpenShift Virtualization's per-VM memory overhead: 0.2% of guest memory, 218 MiB for virt-launcher, 8 MiB per
    /// vCPU and 16 MiB for the graphics device (Red Hat, OpenShift Virtualization "Preparing your cluster", 4.13+).
    static func openShiftOverheadGiB(_ vm: VM) -> Double {
        (vm.memoryMiB * 0.002 + 218 + 8 * Double(vm.cpus) + 16) / 1024
    }

    /// Workload groups sized separately, added up; loads are the worst group's.
    static func combine(_ parts: [Plan]) -> Plan {
        var out = parts.count == 1 ? parts[0] : Plan()
        out.groupHosts = parts.map { $0.feasible ? $0.total : 0 }
        guard parts.count > 1 else { return out }
        out.feasible = parts.allSatisfy(\.feasible)
        out.maxLoad = parts.first?.maxLoad ?? 1
        for q in parts {
            out.hosts += q.hosts; out.clusters += q.clusters; out.control += q.control
            out.cpuLoad = max(out.cpuLoad, q.cpuLoad); out.memLoad = max(out.memLoad, q.memLoad); out.activeLoad = max(out.activeLoad, q.activeLoad)
            out.vmLoad = max(out.vmLoad, q.vmLoad); out.vcpuLoad = max(out.vcpuLoad, q.vcpuLoad); out.storageLoad = max(out.storageLoad, q.storageLoad)
        }
        return out
    }

    /// The fewest hosts that carry the demand at `maxLoad` with `spare` hosts down in every cluster, clusters split at
    /// the platform's maximum and each at least its minimum.
    static func size(_ d: Demand, vmOverheadGiB: Double, _ pr: Profile, host: HostSpec, spare: Int, maxLoad: Double) -> Plan {
        let cores = host.cores - pr.hostCores, dram = host.ramGiB - pr.hostRAM
        guard cores > 0, dram > 0 else { return Plan(feasible: false) }
        let ram = d.ramGiB / max(pr.density, 1) + vmOverheadGiB
        let perCluster = max(pr.maxHosts, pr.minHosts, spare + 1)
        for h in 1...20_000 {
            var clusters = Int((Double(h) / Double(perCluster)).rounded(.up))
            if pr.maxVMsPerCluster > 0 { clusters = max(clusters, Int((Double(d.vms) / Double(pr.maxVMsPerCluster)).rounded(.up))) }
            guard h >= clusters * max(pr.minHosts, spare + 1) else { continue }
            let live = Double(h - clusters * spare)
            var p = Plan(hosts: h, clusters: clusters, control: clusters * pr.control)
            p.maxLoad = maxLoad
            p.cpuLoad = (d.cores + pr.clusterCores * Double(clusters)) / (live * cores)
            p.memLoad = (ram + pr.clusterRAM * Double(clusters)) / (live * dram * (1 + pr.tier))
            if pr.tier > 0, let active = d.activeGiB { p.activeLoad = (active + vmOverheadGiB) / (live * dram) }
            // Hard limits hold with the failover hosts down; storage counts every host.
            if pr.maxVMsPerHost > 0 { p.vmLoad = Double(d.vms) / (live * Double(pr.maxVMsPerHost)) }
            if pr.maxVCPUPerHost > 0 { p.vcpuLoad = d.vcpus / (live * Double(pr.maxVCPUPerHost)) }
            if pr.rawPerHostMiB > 0, let f = pr.storage(h / clusters) { p.storageLoad = d.usableMiB * f / (Double(h) * pr.rawPerHostMiB) }
            if p.fits { return p }
        }
        return Plan(feasible: false)
    }

    func profile(_ pl: Platform, _ p: Params, vms: Int, host: HostSpec) -> Profile {
        typealias A = VCFAppliances
        let k = pl.key
        var pr = Profile(platform: pl)
        pr.density = p.num(k + "Mem") / 100
        pr.hostCores = p.num(k + "Cores")
        pr.hostRAM = p.num(k + "RAM")
        pr.maxHosts = Int(p.num(k + "Max"))
        pr.minHosts = Int(p.num(k + "Min"))
        let factor = p.num(k + "Storage")
        pr.storage = { _ in factor > 0 ? factor : nil }
        pr.rawPerHostMiB = p.num(k + "RawTB") * 1e12 / 1_048_576
        if pl.isVMware {
            let policy = p.choice("vsStorage")
            pr.storage = { n in [n >= 6 ? 1.25 : 1.5, 1.5, 2.0, nil][min(policy, 3)] }
            if pl != .vsphere8, p.flag("vsTier") { pr.tier = p.num("vsTierRatio") / 100 }
        } else {
            let cpu = p.num(k + "MgmtCPU"), ram = p.num(k + "MgmtRAM")
            let custom = pl != .ahv || p.choice("ahvPC") == 5
            let pdm = pl == .kvm && p.choice("kvmFlavor") == 1 && p.flag("pxPDM")
            let vmm = pl == .hyperv && p.flag("hvVMM")
            if pdm || vmm || (custom && (cpu > 0 || ram > 0)) {
                pr.management = { _, _ in
                    (pdm ? [Component(name: "Proxmox Datacenter Manager", nodes: 1, cpu: 2, ram: 4, disk: 40)] : [])
                        + (vmm ? [Component(name: "System Center VMM server", nodes: 1, cpu: 4, ram: 16, disk: 60, note: "estimate"),
                                  Component(name: "SQL Server for VMM", nodes: 1, cpu: 4, ram: 16, disk: 100, note: "estimate")] : [])
                        + (cpu > 0 || ram > 0 ? [Component(name: "Management VMs", nodes: 1, cpu: cpu, ram: ram, disk: 0)] : [])
                }
            } else if pl == .ahv, p.choice("ahvPC") < 5 {
                let pick = p.choice("ahvPC")
                pr.management = { hosts, clusters in
                    let size = pick > 0 ? pick : (hosts <= 50 && clusters <= 5 && vms <= 500 ? 1 : 2)
                    let pc = AlternateHypervisors.prismCentral[size - 1]
                    return [Component(name: "Prism Central", nodes: 1, cpu: pc.cpu, ram: pc.ram, disk: pc.disk, note: pc.name)]
                }
            }
        }
        switch pl {
        case .vsphere8:
            if p.flag("vs8VC"), let vc = A.vcenter["Medium"] {
                pr.management = { _, _ in [Component(name: "vCenter", nodes: 1, cpu: vc.cpu, ram: vc.ram, disk: A.vcenterDisk["Medium"]!["Default"]!, note: "Medium")] }
            }
        case .vvf:
            let newVC = p.choice("vvfVC") == 1, services = p.flag("vvfServices")
            pr.management = { _, _ in
                VCF9Sizing.vvfComponents(newVCenter: newVC, services: services, proxy: false, logs: nil, logReplicas: 3, extra: A.Spec(0, 0, 0))
            }
            pr.mgmtDedicated = p.choice("vvfArch") == 1
            pr.mgmtMinHosts = max(pr.minHosts, 3)
        case .vcf:
            let deploy = A.Deployment(rawValue: p.choice("vcfDeploy")) ?? .haSmall
            let dedicated = p.choice("vcfArch") == 0, ops = p.flag("vcfOps")
            pr.management = { hosts, clusters in
                // Dedicated: the workload domain's vCenter and NSX Managers run in the management domain. Consolidated:
                // the management domain is the workload cluster and has no workload domain.
                let wld = dedicated ? [VCF9Sizing.WorkloadDomain(name: "Workload domain", clusters: [], hosts: hosts, vms: vms,
                                                                 vcSize: A.vcenterSize(hosts: hosts, vms: vms),
                                                                 nsxSize: A.nsxSize(hosts: hosts, clusters: clusters))] : []
                return VCF9Sizing.managementComponents(deploy, vcfOps: ops, vcfAuto: false, logs: nil, logReplicas: 3, rtm: false, edges: nil,
                                                       mgmtNSXSize: deploy == .haLarge ? "Large" : "Medium", extra: A.Spec(0, 0, 0),
                                                       domains: wld, newVCenters: true, wldNSXNodes: 3)
            }
            pr.mgmtDedicated = dedicated
            pr.mgmtMinHosts = max(pr.minHosts, deploy.isHA ? 4 : 3)
        case .hyperv:
            pr.hostRAM += 4 * p.num("hvCacheTB")
            pr.maxVMsPerHost = Int(p.num("hvHostVMs"))
            pr.maxVCPUPerHost = Int(p.num("hvHostVCPU"))
            pr.maxVMsPerCluster = Int(p.num("hvClusterVMs"))
        case .kvm:
            switch p.choice("kvmFlavor") {
            case 2:   // Scale Computing HyperCore
                pr.hostCores = p.num("scCores"); pr.hostRAM = p.num("scRAM")
                pr.maxHosts = Int(p.num("scMax")); pr.minHosts = Int(p.num("scMin"))
                let f = p.num("scStorage")
                pr.storage = { _ in f }
            case 3:   // VergeOS: 16 GB plus 1 GB per raw TB, a core per storage disk, 2 or 3 copies, no ballooning
                let raw = p.num("pxRawTB") > 0 ? p.num("pxRawTB") : p.num("vgRawTB")
                let n2 = p.choice("vgRedundancy") == 1
                pr.hostCores = p.num("vgDisks"); pr.hostRAM = 16 + raw
                pr.maxHosts = Int(p.num("vgMax")); pr.minHosts = n2 ? 3 : 2
                pr.storage = { _ in n2 ? 3 : 2 }
                pr.density = 1
            default:  // Generic KVM and Proxmox VE, with Ceph
                let osds = p.num("pxOSDs")
                pr.hostCores += osds * p.num("pxOSDCores")
                pr.hostRAM += osds * p.num("pxOSDRAM")
                if osds > 0 { pr.clusterCores = p.num("pxCephSvcCores") }
            }
        case .openshift:
            let drives = p.num("ocpDrives")
            if drives > 0 {
                // ODF's figures are logical CPUs; halved to cores, as hyperthreaded hosts give two per core.
                pr.hostCores += (10 + 2 * (drives - 1)) / 2
                pr.hostRAM += 24 + 5 * (drives - 1)
            }
            let reserve = AlternateHypervisors.openShiftNodeReserve(effectiveCores: host.cores, ramGiB: host.ramGiB)
            pr.hostCores += reserve.cores; pr.hostRAM += reserve.ramGiB
            pr.perVMOverhead = true
            pr.control = Int(p.num("ocpControl"))
            pr.maxVMsPerHost = Int(p.num("ocpMaxPods"))
            pr.clusterCores = p.num("ocpInfraCores"); pr.clusterRAM = p.num("ocpInfraRAM")
            pr.fixedHosts = Int(p.num("ocpHub"))
        case .ahv: break
        }
        return pr
    }

    /// The median host by memory behind the VMs, as the model for new hosts.
    static func typicalHost(_ hosts: [Host]) -> Host? {
        let sorted = hosts.filter { !$0.inferred && !$0.isVirtual && $0.cores > 0 && $0.memoryMiB > 0 }
            .sorted { ($0.memoryMiB, $0.cores) < ($1.memoryMiB, $1.cores) }
        return sorted.isEmpty ? nil : sorted[sorted.count / 2]
    }

    // MARK: - Run

    public func run(vms: [VM], inventory inv: Inventory, params p: Params) -> SolutionResult {
        // The KVM platform is named after the chosen flavor.
        let flavor = min(p.choice("kvmFlavor"), AlternateHypervisors.kvmFlavors.count - 1)
        func nm(_ pl: Platform) -> String { pl == .kvm ? AlternateHypervisors.kvmFlavors[flavor] + (flavor == 0 ? "" : " (KVM)") : pl.name }
        func sh(_ pl: Platform) -> String { pl == .kvm ? AlternateHypervisors.kvmShort[flavor] : pl.short }
        // The VMs that need compute: running and suspended by default, or every VM, or running only.
        let include = p.choice("include")
        let running = vms.filter { vm in
            vm.isVM && (vm.isRunning || (include == 0 && vm.powerState == .suspended) || include == 1)
        }
        let includedLabel = ["powered on or suspended", "powered on or off", "powered on"][min(include, 2)]
        let hostIDs = Set(vms.map(\.hostKey))
        let hostsToday = inv.hosts.filter { hostIDs.contains($0.id) && !$0.isVirtual }
        let picked = p.names("hostModel").first.flatMap { HostSpecs.resolve($0, in: inv) }.flatMap { AlternateHypervisors.typicalHost([$0]) }
        let missingPick = !p.names("hostModel").isEmpty && picked == nil
        let model = picked ?? AlternateHypervisors.typicalHost(hostsToday) ?? AlternateHypervisors.typicalHost(inv.hosts)
        var host = HostSpec(cores: Double(model?.cores ?? 0), ramGiB: (model?.memoryMiB ?? 0) / 1024,
                            mhz: model?.speedMHz ?? 0, name: model.map { (picked != nil ? "like " : "typical, like ") + $0.name } ?? "")
        if p.num("hostCores") > 0 { host.cores = p.num("hostCores"); host.name = "custom" }
        if p.num("hostRAM") > 0 { host.ramGiB = p.num("hostRAM"); host.name = "custom" }
        // Hyperthreading credit: each extra thread counts as a share of a core, on every platform.
        let htCredit = p.num("htCredit") / 100
        host.physical = host.cores
        host.threads = model?.htActive == true || (model == nil && p.num("hostCores") > 0) ? host.cores * 2 : host.cores
        host.cores = host.physical + (host.threads - host.physical) * htCredit
        let hostLabel = "\(SFmt.num(host.cores)) cores, \(Fmt.memory(mib: host.ramGiB * 1024))" + (host.name.isEmpty ? "" : " (\(host.name))")

        guard !running.isEmpty, host.cores > 0, host.ramGiB > 0 else {
            let why = running.isEmpty ? "No \(includedLabel) VMs selected." : "No host to model: set cores and memory per host under Target hosts."
            return SolutionResult(headline: why, sections: [.notes("Nothing to size", [why])])
        }

        // Demand, on the same basis for every platform.
        let measured = p.choice("basis") == 1
        let fixedRatio = max(p.num("cpuRatio"), 0.1)
        let todaysRatio = p.choice("ratioMode") == 1
        let speed = max(p.num("cpuSpeed"), 0.1)
        let mgmtRatio = max(p.num("mgmtRatio"), 0.1)
        // Today's ratio per source cluster: its powered-on vCPUs over its hosts' cores, kept within 1:1 to 15:1.
        let ratioByCluster: [String: Double] = {
            let cores = Dictionary(grouping: inv.hosts.filter { !$0.isVirtual && $0.cores > 0 }, by: \.clusterKey).mapValues { $0.reduce(0) { $0 + $1.cores } }
            let vcpus = Dictionary(grouping: inv.vms.filter { $0.isVM && $0.isRunning }, by: \.clusterKey).mapValues { $0.reduce(0) { $0 + $1.cpus } }
            return Dictionary(uniqueKeysWithValues: cores.filter { $0.value > 0 }.map { key, n in
                (key, min(15, max(1, Double(vcpus[key] ?? 0) / Double(n))))
            })
        }()
        func ratio(_ vm: VM) -> Double { todaysRatio ? (ratioByCluster[vm.clusterKey] ?? fixedRatio) : fixedRatio }
        func clusterLabel(_ key: String) -> String {
            guard let c = inv.clusters.first(where: { $0.id == key }) else { return "(no cluster)" }
            return c.isStandalone ? "Standalone hosts (\(c.datacenter.isEmpty ? c.vcenter : c.datacenter))" : c.name
        }

        // Storage: every selected VM, in use (excluding swap) or provisioned, plus growth, with the free-space reserve kept.
        let growth = 1 + p.num("growth") / 100
        let reserve = min(p.num("reserve") / 100, 0.95)
        let provisioned = p.choice("storageBasis") == 1
        func storageMiB(_ vm: VM) -> Double {
            (provisioned ? (vm.diskCapacityMiB > 0 ? vm.diskCapacityMiB : vm.provisionedMiB) : vm.inUseExcludingSwapMiB) * growth / (1 - reserve)
        }

        // Active memory only counts when most VMs report it; VMs without it are taken at their sized memory.
        let useActive = running.filter { $0.memActiveMiB > 0 }.count * 2 >= running.count
        var measuredFallback = 0

        /// Workload groups: one pool, or one per source cluster that has VMs to size. Storage of VMs in other clusters
        /// (powered off, say) goes to the largest group.
        struct Group { let key: String, name: String; var d: Demand; var ocp: Double; var ratio: Double }
        let keepClusters = p.choice("clusterMode") == 1
        var groups: [Group] = []
        let byKey = Dictionary(grouping: running, by: { keepClusters ? $0.clusterKey : "" })
        for key in byKey.keys.sorted(by: { clusterLabel($0).localizedCaseInsensitiveCompare(clusterLabel($1)) == .orderedAscending }) {
            var g = Group(key: key, name: keepClusters ? clusterLabel(key) : "All VMs", d: Demand(), ocp: 0, ratio: 0)
            var active = 0.0
            for vm in byKey[key]! {
                g.d.vms += 1
                g.d.vcpus += Double(vm.cpus)
                if measured, vm.isRunning, vm.cpuUsageMHz > 0, host.mhz > 0, vm.memConsumedMiB > 0 {
                    g.d.cores += vm.cpuUsageMHz / host.mhz / speed
                    g.d.ramGiB += vm.memConsumedMiB / 1024
                } else {
                    if measured && vm.isRunning { measuredFallback += 1 }
                    g.d.cores += Double(vm.cpus) / ratio(vm) / speed
                    g.d.ramGiB += vm.memoryMiB / 1024
                }
                active += vm.memActiveMiB > 0 ? vm.memActiveMiB / 1024 : vm.memoryMiB / 1024
                g.ocp += AlternateHypervisors.openShiftOverheadGiB(vm)
            }
            if useActive { g.d.activeGiB = active }
            let cpuOnly = byKey[key]!.reduce(0.0) { $0 + Double($1.cpus) / ratio($1) }
            g.ratio = cpuOnly > 0 ? g.d.vcpus / cpuOnly : fixedRatio
            groups.append(g)
        }
        let groupIDs = Set(groups.map(\.key))
        let largest = groups.indices.max { groups[$0].d.ramGiB < groups[$1].d.ramGiB } ?? 0
        for vm in vms where vm.isVM {
            let key = keepClusters ? vm.clusterKey : ""
            groups[groupIDs.contains(key) ? groups.firstIndex { $0.key == key }! : largest].d.usableMiB += storageMiB(vm)
        }
        let d = groups.dropFirst().map(\.d).reduce(groups[0].d, +)
        let ocpOverhead = groups.reduce(0) { $0 + $1.ocp }
        let overallRatio = d.vcpus / max(groups.reduce(0) { $0 + $1.d.vcpus / $1.ratio }, 0.001)

        let spare = Int(p.num("spare"))
        let maxLoad = p.num("maxLoad") / 100
        let chosen = p.multi("platforms").compactMap { i in Platform.alternates.indices.contains(i) ? Platform.alternates[i] : nil }
        let baseline = Platform.editions[min(p.choice("baseline"), Platform.editions.count - 1)]
        let editions: [Platform] = [.vsphere8, .vvf, .vcf]
        let platforms = editions + chosen
        let profiles = Dictionary(uniqueKeysWithValues: platforms.map { ($0, profile($0, p, vms: running.count, host: host)) })

        /// Management appliances count at the management vCPU ratio; their memory is all active.
        func demand(_ comps: [Component]) -> Demand {
            let ram = comps.reduce(0) { $0 + $1.ram }
            let cpu = comps.reduce(0) { $0 + $1.cpu }
            return Demand(cores: cpu / mgmtRatio, ramGiB: ram, activeGiB: ram, vms: comps.reduce(0) { $0 + max($1.nodes, 1) }, vcpus: cpu,
                          usableMiB: comps.reduce(0) { $0 + $1.disk } * 1024 / (1 - reserve))
        }
        /// The platform's hosts, plus a fixed management cluster (an ACM hub) when it has one.
        func plan(_ pr: Profile) -> Plan {
            var out = planWorkloads(pr)
            if out.feasible, pr.fixedHosts > 0 {
                out.hosts += pr.fixedHosts; out.clusters += 1
                out.mgmtHosts += pr.fixedHosts; out.mgmtClusters += 1
            }
            return out
        }
        func planWorkloads(_ pr: Profile) -> Plan {
            /// Every group sized as its own cluster(s); `extra` (management in the workload cluster) goes in the largest.
            func workloads(_ extra: Demand) -> Plan {
                AlternateHypervisors.combine(groups.indices.map { i in
                    AlternateHypervisors.size(i == largest ? groups[i].d + extra : groups[i].d, vmOverheadGiB: pr.perVMOverhead ? groups[i].ocp : 0,
                                              pr, host: host, spare: spare, maxLoad: maxLoad)
                })
            }
            let first = workloads(Demand())
            guard first.feasible else { return first }
            let comps = pr.management(first.hosts, first.clusters)
            let md = demand(comps)
            guard !md.isEmpty else { return first }
            if pr.mgmtDedicated {
                var mp = pr
                mp.minHosts = max(pr.minHosts, pr.mgmtMinHosts); mp.perVMOverhead = false; mp.control = 0
                let m = AlternateHypervisors.size(md, vmOverheadGiB: 0, mp, host: host, spare: spare, maxLoad: maxLoad)
                guard m.feasible else { return m }
                var out = first
                out.hosts += m.hosts; out.clusters += m.clusters
                out.mgmtHosts = m.hosts; out.mgmtClusters = m.clusters
                out.mgmt = comps
                return out
            }
            // In the workload cluster: size with the appliances, then once more in case their size grew with the hosts.
            var out = workloads(md)
            guard out.feasible else { return out }
            let again = pr.management(out.hosts, out.clusters)
            if demand(again).ramGiB > md.ramGiB || demand(again).cores > md.cores { out = workloads(demand(again)) }
            out.mgmt = again
            return out
        }
        let plans = profiles.mapValues(plan)
        let base = plans[baseline]!

        func rawMiB(_ pl: Platform) -> Double? {
            guard let pr = profiles[pl], let pn = plans[pl], pn.feasible, pn.clusters > 0,
                  let f = pr.storage((pn.hosts - pn.mgmtHosts) / max(pn.clusters - pn.mgmtClusters, 1)) else { return nil }
            return (d.usableMiB + demand(pn.mgmt).usableMiB) * f
        }

        func delta(_ n: Int) -> String { n == 0 ? "same" : (n > 0 ? "+\(n)" : "−\(-n)") }
        func vsBase(_ pn: Plan) -> String {
            guard pn.feasible, base.feasible else { return "—" }
            let diff = pn.total - base.total
            return delta(diff) + (base.total > 0 && diff != 0 ? " (\(diff > 0 ? "+" : "−")\(Fmt.pct(Double(abs(diff)) / Double(base.total) * 100)))" : "")
        }
        func hosts(_ pn: Plan) -> String { pn.feasible ? Fmt.int(pn.total) : "—" }
        func clustersText(_ pn: Plan) -> String {
            "\(pn.clusters) cluster\(pn.clusters == 1 ? "" : "s")" + (pn.mgmtHosts > 0 ? " incl. \(pn.mgmtHosts)-host management" : "")
        }

        // Summary
        var metrics = [
            SolutionMetric("VMs sized", Fmt.int(running.count), "\(includedLabel), of \(Fmt.int(vms.count)) selected", symbol: "desktopcomputer"),
            SolutionMetric("Demand", "\(SFmt.num(d.cores.rounded(.up))) cores · \(Fmt.memory(mib: d.ramGiB * 1024))",
                           (measured ? "measured CPU and consumed memory" : "\(Fmt.int(Int(d.vcpus))) vCPU at " + (todaysRatio ? "today's ratios (\(Fmt.ratio(overallRatio)) overall)" : "\(SFmt.num(fixedRatio)):1"))
                               + (speed != 1 ? " · cores ÷ \(SFmt.num(speed)) for per-core speed" : ""),
                           symbol: "cpu"),
            SolutionMetric("Host model", "\(SFmt.num(host.physical)) cores · \(Fmt.memory(mib: host.ramGiB * 1024))",
                           (host.name.isEmpty ? "" : host.name + " · ") + (host.cores != host.physical ? "\(SFmt.num(host.cores)) effective with hyperthreading · " : "") + "same on every platform · today \(Fmt.int(hostsToday.count)) hosts", symbol: "server.rack"),
        ]
        for pl in [baseline] + editions.filter({ $0 != baseline }) + chosen {
            let pn = plans[pl]!
            let detail = !pn.feasible ? "per-host overhead leaves nothing for VMs"
                : (pl == baseline ? clustersText(pn) + " · sized by \(pn.driver.lowercased())" : "\(vsBase(pn)) vs \(baseline.short)")
            metrics.append(SolutionMetric(sh(pl), pn.feasible ? "\(Fmt.int(pn.total)) hosts" : "Doesn't fit", detail,
                                          symbol: pl.isVMware ? "checkmark.seal" : "server.rack", status: pn.feasible ? nil : .blocker))
        }

        // Hosts by platform
        var rows: [[String]] = []
        for pl in platforms {
            let pn = plans[pl]!, pr = profiles[pl]!
            let cores = host.cores - pr.hostCores, dram = host.ramGiB - pr.hostRAM
            let mem = Fmt.memory(mib: max(0, dram) * 1024) + (pr.tier > 0 ? " + \(Fmt.memory(mib: max(0, dram) * pr.tier * 1024)) NVMe" : "")
            rows.append([nm(pl), hosts(pn), pl == baseline ? "baseline" : vsBase(pn), pn.feasible ? Fmt.int(pn.clusters) : "—",
                         pn.feasible ? Fmt.int(pn.clusters * spare) : "—", pn.mgmtHosts > 0 ? Fmt.int(pn.mgmtHosts) : "",
                         pn.control > 0 ? Fmt.int(pn.control) : "",
                         SFmt.num(max(0, cores)), mem, pr.density > 1 ? "\(Fmt.pct(pr.density * 100))" : "1:1",
                         pn.feasible ? Fmt.pct(pn.load * 100) : "—", pn.driver, pn.feasible ? rawMiB(pl).map { Fmt.capacity(mib: $0) } ?? "External" : "—"])
        }
        let hostsTable = SolutionTable(id: "hosts", title: "Hosts by platform",
                                       subtitle: "Same VMs, same host model, \(spare) host failure\(spare == 1 ? "" : "s") tolerated per cluster at up to \(Fmt.pct(maxLoad * 100)) load. Hosts include spares, management and control-plane nodes; load is the workload clusters'.",
                                       columns: ["Platform", "Hosts", "vs \(baseline.short)", "Clusters", "Spare hosts", "Management hosts", "Control-plane nodes",
                                                 "Cores per host for VMs", "Memory per host for VMs", "Memory overcommit", "Load", "Sized by", "Raw storage"],
                                       numeric: [1, 3, 4, 5, 6, 7, 10], rows: rows, emphasized: [platforms.firstIndex(of: baseline)!])

        // Hosts per source cluster (keep today's clusters)
        var perClusterRows: [[String]] = groups.indices.map { i in
            [groups[i].name, Fmt.int(groups[i].d.vms), Fmt.ratio(groups[i].ratio)]
                + platforms.map { pl in plans[pl].flatMap { $0.feasible && $0.groupHosts.indices.contains(i) ? Fmt.int($0.groupHosts[i]) : nil } ?? "—" }
        }
        if platforms.contains(where: { (plans[$0]?.mgmtHosts ?? 0) > 0 }) {
            perClusterRows.append(["Management cluster", "", ""] + platforms.map { pl in (plans[pl]?.mgmtHosts ?? 0) > 0 ? Fmt.int(plans[pl]!.mgmtHosts) : "" })
        }
        perClusterRows.append(["Total", Fmt.int(d.vms), Fmt.ratio(overallRatio)] + platforms.map { hosts(plans[$0]!) })
        let perClusterTable = SolutionTable(id: "clusters", title: "Hosts per source cluster",
                                            subtitle: "Each source cluster's VMs sized as their own cluster, with its own minimum size and spare hosts. Management in the workload cluster goes in the largest one.",
                                            columns: ["Source cluster", "VMs", "vCPU per core"] + platforms.map(sh),
                                            numeric: Set(1..<(3 + platforms.count)), rows: perClusterRows, emphasized: [perClusterRows.count - 1])

        // Where the extra hosts come from: swap one baseline assumption at a time for the platform's.
        var gapRows: [[String]] = []
        let vs = profiles[baseline]!
        for pl in chosen {
            let target = profiles[pl]!
            var step = vs
            var counts = [base]
            step.management = target.management; step.mgmtDedicated = target.mgmtDedicated; step.mgmtMinHosts = target.mgmtMinHosts
            step.clusterCores = target.clusterCores; step.clusterRAM = target.clusterRAM; step.fixedHosts = target.fixedHosts
            counts.append(plan(step))
            step.density = target.density; step.tier = target.tier
            counts.append(plan(step))
            step.hostCores = target.hostCores; step.hostRAM = target.hostRAM
            counts.append(plan(step))
            step.perVMOverhead = target.perVMOverhead; step.control = target.control
            counts.append(plan(step))
            step.maxHosts = target.maxHosts; step.minHosts = target.minHosts
            step.maxVMsPerHost = target.maxVMsPerHost; step.maxVCPUPerHost = target.maxVCPUPerHost; step.maxVMsPerCluster = target.maxVMsPerCluster
            counts.append(plan(step))
            step.storage = target.storage; step.rawPerHostMiB = target.rawPerHostMiB
            counts.append(plan(step))
            guard counts.allSatisfy(\.feasible) else {
                gapRows.append([nm(pl), Fmt.int(base.total), "—", "—", "—", "—", "—", "—", "Doesn't fit"])
                continue
            }
            let steps = zip(counts.dropFirst(), counts).map { $0.total == $1.total ? "0" : delta($0.total - $1.total) }
            gapRows.append([nm(pl), Fmt.int(base.total)] + steps + [Fmt.int(counts.last!.total)])
        }
        let gapTable = SolutionTable(id: "gap", title: "Where the difference in hosts comes from",
                                     subtitle: "Starting from \(baseline.short), each column swaps in one of the platform's assumptions, in this order. Another order can move hosts between columns; the total doesn't change.",
                                     columns: ["Platform", "\(baseline.short) hosts", "Management components", "Memory overcommit and tiering", "Per-host overhead",
                                               "Per-VM overhead and control plane", "Host and cluster limits", "Storage", "Platform hosts"],
                                     numeric: [1, 2, 3, 4, 5, 6, 7, 8], rows: gapRows)

        // Management components: appliances and management VMs, plus what's counted per cluster or as nodes of its own.
        var mgmtRows: [[String]] = []
        for pl in platforms {
            guard let pn = plans[pl], pn.feasible, let pr = profiles[pl] else { continue }
            let workloadClusters = max(pn.clusters - pn.mgmtClusters, 0)
            let dedicated = pr.mgmtDedicated ? pn.mgmtHosts - pr.fixedHosts : 0
            let place = pr.mgmtDedicated ? "Own cluster (\(dedicated) hosts)" : "Workload cluster"
            var rows: [[String]] = pn.mgmt.map { c in
                [sh(pl), c.name + (c.note.isEmpty ? "" : " (\(c.note))"), c.nodes > 0 ? Fmt.int(c.nodes) : "",
                 SFmt.num(c.cpu), SFmt.num(c.ram), SFmt.num(c.disk), place]
            }
            if pr.clusterCores > 0 || pr.clusterRAM > 0 {
                let name = pl == .openshift ? "Infrastructure workloads (ingress, registry, monitoring, logging)" : "Ceph monitors and managers"
                let per = (pr.clusterRAM > 0 ? "\(SFmt.num(pr.clusterCores)) cores and \(Fmt.memory(mib: pr.clusterRAM * 1024))" : "\(SFmt.num(pr.clusterCores)) cores") + " per cluster"
                rows.append([sh(pl), "\(name) — \(per)", "", "\(SFmt.num(pr.clusterCores * Double(workloadClusters))) cores",
                             pr.clusterRAM > 0 ? SFmt.num(pr.clusterRAM * Double(workloadClusters)) : "", "",
                             "Workload cluster\(workloadClusters == 1 ? "" : "s") (\(workloadClusters))"])
            }
            if pn.control > 0 {
                rows.append([sh(pl), "Dedicated control-plane nodes", Fmt.int(pn.control), "", "", "", "Own nodes (\(pn.control) hosts)"])
            }
            if pr.fixedHosts > 0 {
                rows.append([sh(pl), "Advanced Cluster Management hub", Fmt.int(pr.fixedHosts), "", "", "", "Own cluster (\(pr.fixedHosts) hosts)"])
            }
            guard !rows.isEmpty else { continue }
            let t = demand(pn.mgmt)
            let cores = t.cores + pr.clusterCores * Double(workloadClusters)
            let ram = t.ramGiB + pr.clusterRAM * Double(workloadClusters)
            let nodes = pn.control + pr.fixedHosts + dedicated
            let summary = "\(SFmt.num((cores * 10).rounded() / 10)) cores" + (pn.mgmt.isEmpty ? "" : " (VMs at \(SFmt.num(mgmtRatio)):1)")
                + (nodes > 0 ? " · \(nodes) hosts of their own" : "")
            mgmtRows += rows
            let vms = !pn.mgmt.isEmpty
            mgmtRows.append([sh(pl), "Total", "", vms ? SFmt.num(pn.mgmt.reduce(0) { $0 + $1.cpu }) : "", ram > 0 ? SFmt.num(ram) : "",
                             vms ? SFmt.num(pn.mgmt.reduce(0) { $0 + $1.disk }) : "", summary])
        }
        let mgmtTable = SolutionTable(id: "management", title: "Management components",
                                      subtitle: "Everything counted for managing each platform. VCF and VVF appliance sizes follow the \(VCFAppliances.source) and VCF 9.1 installer defaults, as in VCF 9 Sizing; the others' sources are in the assumptions. vSphere 8 and VVF 9 keep the existing vCenter unless set otherwise; the alternates are new deployments, so their managers are counted.",
                                      columns: ["Platform", "Component", "Nodes", "vCPU", "Memory (GB)", "Disk (GB)", "Runs on"], numeric: [2, 3, 4, 5],
                                      rows: mgmtRows, emphasized: Set(mgmtRows.indices.filter { mgmtRows[$0][1] == "Total" }))

        // Per-host overhead
        let what: [Platform: String] = [
            .vsphere8: "ESXi and vSAN ESA", .vvf: "ESXi and vSAN ESA", .vcf: "ESXi and vSAN ESA",
            .hyperv: "Management OS, clustering and Storage Spaces Direct" + (p.num("hvCacheTB") > 0 ? " (incl. \(SFmt.num(4 * p.num("hvCacheTB"))) GiB for S2D cache)" : ""),
            .ahv: "Controller VM (storage) and AHV",
            .kvm: [flavor == 2 ? "HyperCore with SCRIBE storage (estimate)"
                   : flavor == 3 ? "VergeOS: 16 GiB plus 1 GiB per raw TB, a core per storage disk"
                   : "KVM host plus \(SFmt.num(p.num("pxOSDs"))) Ceph OSDs" + (p.num("pxOSDs") > 0 ? "; \(SFmt.num(p.num("pxCephSvcCores"))) more cores per cluster for Ceph monitors and managers" : "")][0],
            .openshift: "Kubelet reserved and OpenShift Virtualization (Red Hat's formula)" + (p.num("ocpDrives") > 0 ? " plus OpenShift Data Foundation for \(SFmt.num(p.num("ocpDrives"))) drives" : "")
                + (p.num("ocpInfraCores") + p.num("ocpInfraRAM") > 0 ? "; infrastructure workloads add \(SFmt.num(p.num("ocpInfraCores"))) cores and \(Fmt.memory(mib: p.num("ocpInfraRAM") * 1024)) per cluster" : "")
                + "; per VM, virt-launcher adds \(Fmt.memory(mib: ocpOverhead * 1024)) in all",
        ]
        let overheadTable = SolutionTable(id: "overhead", title: "Per-host overhead",
                                          subtitle: "Taken from every host before VMs. Defaults and their sources are in the assumptions.",
                                          columns: ["Platform", "Cores", "Memory", "What it is"], numeric: [1, 2],
                                          rows: ([baseline] + chosen).map { pl in
                                              let pr = profiles[pl]!
                                              return [pl.isVMware ? "vSphere (all editions)" : nm(pl), SFmt.num(pr.hostCores), Fmt.memory(mib: pr.hostRAM * 1024), what[pl] ?? ""]
                                          })

        // Migration considerations
        var cb = CheckBuilder()
        let all = vms.filter(\.isVM)
        cb.list("rdm", "Storage", "Raw device mappings", .warning, noun: "VMs with RDMs",
                affected: all.filter { $0.disks.contains(where: \.raw) }.map { vm in vm.ref("\(vm.disks.filter(\.raw).count) RDM disk(s)") },
                ready: "No RDMs", remediation: "Migration tools convert VMDKs, not RDMs. Plan to present the LUNs to the guest (iSCSI) or move the data.", total: all.count)
        cb.list("shared", "Storage", "Shared or multi-writer disks", .warning, noun: "VMs with shared disks",
                affected: all.filter { $0.disks.contains(where: \.isSharedWriter) }.map { $0.ref("guest cluster or shared disk") },
                ready: "No shared disks",
                remediation: "Guest clusters need each platform's own shared-disk feature (shared VHDX, Nutanix Volume Groups, shared RBD or RWX block volumes) and usually a rebuild.", total: all.count)
        let ft = all.filter { let s = $0.ftState.lowercased(); return !s.isEmpty && s != "notconfigured" && s != "not configured" }
        cb.list("ft", "Availability", "vSphere Fault Tolerance", .warning, noun: "VMs use FT", affected: ft.map { $0.ref("FT: \($0.ftState)") },
                ready: "No FT VMs", remediation: "None of the compared platforms has an equivalent of FT's lockstep secondary VM; these VMs fall back to HA restart or need application clustering.")
        let ref = Lifecycle.supportReference(exportDate: inv.reportDate)
        cb.list("eol", "Guest OS", "Guest OS past end of support", .warning, noun: "VMs",
                affected: all.compactMap { vm in vm.os.endOfSupport.flatMap { $0 <= ref ? vm.ref("\(vm.os.name) — ended \(Fmt.date($0))") : nil } },
                ready: "All guests in support",
                remediation: "Other hypervisors and their migration tools support fewer old guests (drivers such as VirtIO or Hyper-V integration services). Upgrade, or check each platform's guest support list.", total: all.count)
        cb.list("latency", "Performance", "Latency sensitivity set to high", .info, noun: "VMs",
                affected: all.filter { $0.latencySensitivity.lowercased() == "high" }.map { $0.ref("latency sensitivity high") },
                ready: "None", remediation: "Plan CPU pinning or dedicated cores on the target platform.")
        cb.list("usb", "Devices", "USB devices connected", .info, noun: "VMs",
                affected: all.filter { $0.usbConnected > 0 }.map { $0.ref("\($0.usbConnected) USB device(s)") },
                ready: "None", remediation: "USB passthrough works differently on each platform, and on some it blocks live migration; consider USB over IP.")
        if chosen.contains(.ahv) {
            let bp = "Nutanix best practice (BP-2029, \"CPU and memory oversubscription\"): 1:1 to 2:1 for business-critical or latency-sensitive VMs, up to 4:1 for the rest. The Nutanix Sizer warns above 4:1."
            if todaysRatio {
                cb.list("ahv-ratio", "Nutanix AHV", "vCPU per core above 4:1", .warning, noun: "source clusters",
                        affected: groups.flatMap { g -> [AffectedObject] in
                            let keys = keepClusters ? [g.key] : Array(Set(running.map(\.clusterKey)))
                            return keys.compactMap { k in ratioByCluster[k].flatMap { $0 > 4 ? AffectedObject(kind: .cluster, id: k, name: clusterLabel(k), detail: Fmt.ratio($0)) : nil } }
                        }.reduce(into: [AffectedObject]()) { if !$0.contains($1) { $0.append($1) } },
                        ready: "Every source cluster is at 4:1 or below", remediation: bp)
            } else if fixedRatio > 4 {
                cb.add("ahv-ratio", "Nutanix AHV", "vCPU per core above 4:1", .warning, "Sized at \(SFmt.num(fixedRatio)):1", remediation: bp)
            } else {
                cb.add("ahv-ratio", "Nutanix AHV", "vCPU per core above 4:1", .ready, "Sized at \(SFmt.num(fixedRatio)):1")
            }
        }
        if chosen.contains(.openshift) {
            let overcommit = p.num("ocpMem") > 100
            if p.num("ocpControl") == 0 && overcommit {
                cb.add("ocp-control", "OpenShift", "Control plane with memory overcommit", .warning,
                       "No dedicated control-plane nodes, with memory overcommit at \(Fmt.pct(p.num("ocpMem")))",
                       remediation: "Memory overcommit needs swap, and a schedulable (compact) control plane isn't supported with it. Use a hosted control plane on a management cluster, as Red Hat recommends, or 3 to 5 dedicated control-plane nodes. Source: Red Hat, \"OpenShift Virtualization Cluster Sizing Guide\" v3.1.0.")
            }
        }
        if chosen.contains(.hyperv) {
            // Hyper-V runs BIOS VMs as Generation 1 (64 vCPU, 1 TB, IDE boot); Generation 2 needs UEFI.
            let bios = all.filter { $0.firmware.lowercased() == "bios" }
            let source = "Source: Microsoft Learn, \"Hyper-V maximum scale limits\" (Windows Server 2025)."
            cb.list("hv-gen1-limits", "Hyper-V", "BIOS VMs over the Generation 1 limits", .warning, noun: "VMs",
                    affected: bios.filter { $0.cpus > 64 || $0.memoryMiB > 1024 * 1024 }.map { $0.ref("BIOS · \($0.cpus) vCPU, \(Fmt.memory(mib: $0.memoryMiB))") },
                    ready: "Every BIOS VM fits Generation 1",
                    remediation: "Generation 1 VMs allow 64 virtual processors and 1 TB of memory; Generation 2 allows 2,048 and 240 TB but needs UEFI. Convert these guests to UEFI before migrating (for Windows, MBR2GPT), or resize them. " + source)
            cb.list("hv-gen1", "Hyper-V", "BIOS firmware (Generation 1 on Hyper-V)", .info, noun: "VMs use BIOS",
                    affected: bios.map { $0.ref("BIOS firmware") }, ready: "Every VM uses UEFI",
                    remediation: "These VMs become Generation 1 VMs unless converted to UEFI: they boot from IDE, have no Secure Boot, and are limited to 64 virtual processors and 1 TB of memory. " + source,
                    total: all.count)
        }
        for pl in [baseline] + chosen {
            let pr = profiles[pl]!
            let cores = host.cores - pr.hostCores, dram = (host.ramGiB - pr.hostRAM) * (1 + pr.tier)
            let big = running.filter { Double($0.cpus) > host.threads - pr.hostCores || $0.memoryMiB / 1024 > dram }
            cb.list("big-" + pl.id, "Sizing", "VMs too large for one \(sh(pl)) host", .warning, noun: "VMs",
                    affected: big.map { $0.ref("\($0.cpus) vCPU, \(Fmt.memory(mib: $0.memoryMiB))") },
                    ready: "Every VM fits a host after overhead",
                    remediation: "After \(sh(pl))'s per-host overhead, a host has \(SFmt.num(max(0, cores))) cores and \(Fmt.memory(mib: max(0, dram) * 1024)) for VMs. Use larger hosts for these VMs.")
        }

        var notes = [
            "Every platform is sized for the same \(includedLabel) VMs on the same host model (\(hostLabel)), with \(spare) host failure\(spare == 1 ? "" : "s") per cluster and up to \(Fmt.pct(maxLoad * 100)) CPU and memory load.",
            "Management components run at \(SFmt.num(mgmtRatio)) vCPU per core with all their memory active. In their own cluster they get their own spare hosts; in the workload cluster they add to its load.",
            "VCF's management domain also runs NSX networking and security, fleet lifecycle and VCF Operations, which the alternates' figures don't include. Their own add-ons (Nutanix Flow, SCVMM, an OpenShift observability stack and so on) can be added as management VMs.",
            "A dedicated management cluster is sized on the same host model as the workloads; smaller hosts are often enough for it.",
            "Clusters are split at each platform's maximum size, and every cluster keeps its own spare hosts, so lower cluster limits cost extra hosts.",
            "Storage is \(provisioned ? "VM provisioned capacity" : "VM in-use space (excluding swap)") plus \(Fmt.pct(p.num("growth"))) growth and the management components' disks, times each platform's raw-to-usable factor, with \(Fmt.pct(reserve * 100)) kept free. Data reduction is not counted on any platform. Storage adds hosts only where a raw capacity per host is set.",
            "Defaults come from vendor documentation where it exists, and are marked as estimates where it doesn't; each assumption's help names its source. Confirm them against the versions you would deploy.",
        ]
        if chosen.contains(.openshift) {
            // Red Hat's way to pick a memory overcommit: VM memory over host memory in use today.
            let vmMem = inv.vms.filter { $0.isVM && $0.isRunning && hostIDs.contains($0.hostKey) }.reduce(0) { $0 + $1.memoryMiB }
            let used = hostsToday.reduce(0) { $0 + $1.memUsedMiB }
            if used > 0, vmMem > 0 {
                let r = vmMem / used
                notes.append("Today's memory overcommit is \(Fmt.ratio(r)): powered-on VM memory over host memory in use on the hosts behind these VMs. Red Hat's sizing guide suggests planning OpenShift's memory overcommit from this ratio (about \(Fmt.pct((r * 100 / 25).rounded(.down) * 25)) as memoryOvercommitPercentage, with swap); this sizing uses \(Fmt.pct(p.num("ocpMem"))).")
            }
            let reserve = AlternateHypervisors.openShiftNodeReserve(effectiveCores: host.cores, ramGiB: host.ramGiB)
            let infra = p.num("ocpInfraCores") + p.num("ocpInfraRAM") > 0
                ? ", and share \(SFmt.num(p.num("ocpInfraCores"))) cores and \(Fmt.memory(mib: p.num("ocpInfraRAM") * 1024)) of infrastructure workloads per cluster"
                : "; infrastructure workloads aren't counted"
            notes.append("OpenShift Virtualization Engine (OVE) sizes the same: it's a VM-only subscription to the same platform, so node reserves, per-VM overhead, control plane and infrastructure workloads don't change. It doesn't include OpenShift Data Foundation, which comes with OpenShift Platform Plus; for OVE on external storage, set ODF drives to 0 (Red Hat, OVE overview).")
            notes.append("OpenShift worker nodes reserve \(Fmt.num(reserve.cores, 1)) cores and \(Fmt.memory(mib: reserve.ramGiB * 1024)) each by Red Hat's formula and allow up to \(Fmt.int(Int(p.num("ocpMaxPods")))) VMs\(infra).")
        }
        if htCredit > 0 {
            notes.append("Hyperthreading: each extra thread counts as \(Fmt.pct(htCredit * 100)) of a core on every platform, so a host counts as \(SFmt.num(host.cores)) cores.")
        }
        if keepClusters {
            notes.append("Today's clusters are kept: \(groups.count) source cluster\(groups.count == 1 ? "" : "s") sized separately, each with at least the platform's minimum hosts and its own spare.")
        }
        if todaysRatio {
            notes.append("vCPU per core follows each source cluster today (\(Fmt.ratio(overallRatio)) overall), between 1:1 and 15:1.")
        }
        if speed != 1 {
            notes.append("Workloads' CPU need is divided by \(SFmt.num(speed)) for the new hosts' per-core performance; management appliances are not.")
        }
        if chosen.contains(.hyperv) {
            notes.append("Hyper-V's limits are checked with the failover hosts down: \(Fmt.int(Int(p.num("hvHostVMs")))) running VMs and \(Fmt.int(Int(p.num("hvHostVCPU")))) virtual processors per host, and \(Fmt.int(Int(p.num("hvClusterVMs")))) running VMs per cluster (Microsoft Learn, Hyper-V maximum scale limits, Windows Server 2025).")
        }
        if p.flag("vsTier") {
            notes.append(d.activeGiB != nil
                ? "Memory tiering (VVF 9 and VCF 9): active memory (\(Fmt.memory(mib: (d.activeGiB ?? 0) * 1024))) and the management appliances are kept within DRAM; inactive memory can sit on the NVMe tier."
                : "Memory tiering (VVF 9 and VCF 9): the export has no active memory for most VMs, so the sizing can't check that active memory fits in DRAM. Check it before relying on tiering.")
        }
        if missingPick {
            notes.append("The chosen host (\(p.names("hostModel").first.map { String($0.split(separator: "|").last ?? "") } ?? "")) isn't in this export, or has no cores or memory, so the typical host is used.")
        }
        if measuredFallback > 0 { notes.append("\(measuredFallback) VMs had no measured CPU or consumed memory and were sized from their configuration.") }

        let others = editions.filter { $0 != baseline }.compactMap { pl -> String? in
            guard let pn = plans[pl], pn.feasible else { return nil }
            return "\(sh(pl)) \(Fmt.int(pn.total))"
        }
        let alt = chosen.compactMap { pl -> String? in
            guard let pn = plans[pl], base.feasible else { return nil }
            return pn.feasible ? "\(sh(pl)) \(Fmt.int(pn.total)) (\(delta(pn.total - base.total)))" : "\(sh(pl)) doesn't fit"
        }
        let headline = base.feasible
            ? "\(baseline.short) needs \(Fmt.int(base.total)) hosts" + (others.isEmpty ? "" : " (\(others.joined(separator: ", ")))")
                + (alt.isEmpty ? "" : "; " + alt.joined(separator: ", "))
            : "These VMs don't fit the host model on \(baseline.short)"

        return SolutionResult(headline: headline, sections: [
            .metrics("Summary", metrics),
            .table(hostsTable),
        ] + (keepClusters ? [.table(perClusterTable)] : []) + [
            .table(gapTable),
            .table(mgmtTable),
            .table(overheadTable),
            .checks("Migration considerations", cb.checks, subtitle: "What needs work when these VMs leave vSphere, whichever platform they go to."),
            .notes("How it's sized", notes),
        ])
    }
}
