Add-Type -AssemblyName System.Drawing
foreach ($f in @('C:\TrollAutoTouch\A.png','C:\TrollAutoTouch\B.png')) {
  $b=[System.Drawing.Bitmap]::FromFile($f)
  Write-Output ("== " + $f + " " + $b.Width + "x" + $b.Height)
  foreach($c in @(@(98,343),@(93,430),@(105,530),@(102,610),@(97,707),@(82,878),@(161,254),@(130,243))){
    $p=$b.GetPixel($c[0],$c[1])
    Write-Output ("{0},{1}=#{2:X2}{3:X2}{4:X2}" -f $c[0],$c[1],$p.R,$p.G,$p.B)
  }
}