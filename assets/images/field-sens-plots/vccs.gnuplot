set term pngcairo size 400, 400
set output 'vccs.png'
set logscale xy
set xlabel 'no field-sens'
set ylabel 'field-sens'
set xrange [10:10000]
set yrange [10:10000]
set size ratio 1
set title 'Number of VCCs'
plot 'vccs.txt' using 2:1 with points pt 7 ps 1 lc rgb 'blue' notitle, \
    x with line lt 1 lc rgb 'black' notitle

