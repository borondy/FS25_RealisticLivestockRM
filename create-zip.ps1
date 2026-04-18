compress-7Zip -Path ".\animals" -ArchiveFileName "C:\Users\boron\Documents\My Games\FarmingSimulator2025\multiMods\FS25_RealisticLivestockRM_ForVirtualTSZ.zip" -PreserveDirectoryRoot
$files = @(".\fonts", ".\gui", ".\objects", ".\scripts", ".\translations", ".\xml", "icon_RealisticLivestock.dds", "modDesc.xml")
foreach ($file in $files) {
    Compress-7Zip -Append -Path $file -ArchiveFileName "C:\Users\boron\Documents\My Games\FarmingSimulator2025\multiMods\FS25_RealisticLivestockRM_ForVirtualTSZ.zip" -PreserveDirectoryRoot
}
