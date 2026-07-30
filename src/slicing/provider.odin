package slicing

import contracts "../contracts"

CPU_TOPOLOGY_PROVIDER_NAME :: "cpu-canonical-topology"
CPU_TOPOLOGY_PROVIDER_VERSION :: contracts.Semantic_Version{0, 1, 0}
CPU_REGION_PROVIDER_NAME :: "cpu-canonical-regions"
CPU_REGION_PROVIDER_VERSION :: contracts.Semantic_Version{0, 1, 0}

cpu_topology_provider_descriptor :: proc() -> contracts.Provider_Descriptor {
	provider, ok := contracts.provider_descriptor_make(
		CPU_TOPOLOGY_PROVIDER_NAME,
		CPU_TOPOLOGY_PROVIDER_VERSION,
		.Reconstruct_Topology,
	)
	assert(ok)
	return provider
}

cpu_region_provider_descriptor :: proc() -> contracts.Provider_Descriptor {
	provider, ok := contracts.provider_descriptor_make(
		CPU_REGION_PROVIDER_NAME,
		CPU_REGION_PROVIDER_VERSION,
		.Calculate_Regions,
	)
	assert(ok)
	return provider
}
