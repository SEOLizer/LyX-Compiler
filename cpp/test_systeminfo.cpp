#include <iostream>
#include <iomanip>
#include "LyxSystemInfo.hpp"

int main() {
    std::cout << "=== LyxSystemInfo Test ===" << std::endl << std::endl;
    
    LyxSystemInfo::SystemInfoCollector collector;
    
    if (!collector.isInitialized()) {
        std::cerr << "Failed to initialize collector!" << std::endl;
        return 1;
    }
    
    // Initial snapshot
    collector.update();
    const auto& topo = collector.getTopology();
    
    std::cout << "--- CPU Information ---" << std::endl;
    std::cout << "Logical Cores:   " << topo.logical_cores << std::endl;
    std::cout << "Physical Cores: " << topo.physical_cores << std::endl;
    std::cout << "SMT Width:      " << topo.smt_width << std::endl;
    
    std::cout << std::endl << "--- Architecture ---" << std::endl;
    std::cout << "Vendor: " << topo.cpu_info.vendor << std::endl;
    std::cout << "Model:  " << topo.cpu_info.model << std::endl;
    std::cout << "Arch:   " << topo.cpu_info.arch << std::endl;
    
    std::cout << std::endl << "--- Cache Hierarchy ---" << std::endl;
    for (const auto& cache : topo.caches) {
        std::cout << "L" << cache.level << ": " 
                  << (cache.size_bytes / 1024) << " KB "
                  << "(" << cache.type << ")" 
                  << " line=" << cache.line_size << std::endl;
    }
    
    std::cout << std::endl << "--- Memory ---" << std::endl;
    std::cout << "Total:     " << (topo.total_memory_bytes / (1024*1024*1024)) << " GB" << std::endl;
    std::cout << "Available:" << (topo.available_memory_bytes / (1024*1024*1024)) << " GB" << std::endl;
    
    std::cout << std::endl << "--- Per-Core Load ---" << std::endl;
    for (const auto& core : topo.cores) {
        std::cout << "Core " << core.id << ": " 
                  << std::fixed << std::setprecision(1) << (core.load * 100.0f) << "%"
                  << (core.is_hyperthread ? " [HT]" : "") 
                  << std::endl;
    }
    
    std::cout << std::endl << "=== Test Complete ===" << std::endl;
    
    return 0;
}