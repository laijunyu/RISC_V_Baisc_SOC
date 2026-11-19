# XT_RV32I UART 下载脚本
#
# 协议（从 BOOT ROM 反汇编还原）:
#   上位机 -> 'V'(0x56) -> 块数(2字节大端) -> 等芯片就绪 -> 'x'(0x78) -> 数据(块数*16字节)
#   芯片把数据直接写进 RAM[0..]
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File uart_download.ps1 -Port COM3 -File blink.bin
#
# 操作顺序:
#   1. 按住 K1 (key_download) 并按复位，芯片进下载模式
#   2. 运行本脚本
#   3. 松开 K1，再按一次复位 -> 从 RAM 启动

param(
    [Parameter(Mandatory = $true)][string]$Port,
    [Parameter(Mandatory = $true)][string]$File
)

$ErrorActionPreference = "Stop"

$baud      = 19200
$blockSize = 16
$maxBlocks = 480          # 480 * 16 = 7680 字节，RAM 8KB 留余量

$data = [System.IO.File]::ReadAllBytes((Resolve-Path $File))
if ($data.Length -gt $blockSize * $maxBlocks) {
    throw "程序 $($data.Length) 字节，超过上限 $($blockSize * $maxBlocks)"
}

$blocks = [int][math]::Ceiling($data.Length / $blockSize)
$padded = New-Object byte[] ($blocks * $blockSize)
[Array]::Copy($data, $padded, $data.Length)

Write-Host ("端口 {0}  文件 {1}  {2} 字节 -> {3} 块 / {4} 字节" -f `
    $Port, (Split-Path $File -Leaf), $data.Length, $blocks, $padded.Length)

$sp = New-Object System.IO.Ports.SerialPort $Port, $baud, 'None', 8, 'One'
$sp.ReadTimeout = 2000
$sp.Open()
try {
    Start-Sleep -Milliseconds 300
    $sp.DiscardInBuffer()

    # 'V'
    $sp.Write([byte[]]@(0x56), 0, 1)

    # 块数，大端
    $sp.Write([byte[]]@([byte](($blocks -shr 8) -band 0xFF),
                        [byte]($blocks -band 0xFF)), 0, 2)

    Start-Sleep -Milliseconds 50

    # 'x' 确认
    $sp.Write([byte[]]@(0x78), 0, 1)

    # 芯片收到 'x' 后有一段约 300ms 的准备延时，等它过去再发数据，
    # 否则 4 字节 FIFO 会溢出丢数据
    Start-Sleep -Milliseconds 400

    $sp.Write($padded, 0, $padded.Length)
    Write-Host "数据已发送，等待芯片写入 RAM..."
} finally {
    Start-Sleep -Milliseconds 600
    $sp.Close()
}

Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host " 下载完成" -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Green
Write-Host ""
Write-Host "接下来按顺序操作（顺序不能反）：" -ForegroundColor Yellow
Write-Host "  1. 先松开 K1（V20 离开 GND）"
Write-Host "  2. 再按一次复位"
Write-Host ""
Write-Host "如果顺序反了（没松 K1 就复位），会重新进下载模式。" -ForegroundColor DarkGray
