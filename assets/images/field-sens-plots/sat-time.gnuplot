set term pngcairo size 400, 400
set output 'sat-time.png'
set logscale xy
set xlabel 'no field-sens'
set ylabel 'field-sens'
set xrange [0:1000]
set yrange [0:1000]
set size ratio 1
set title 'SAT solving time (s)'
plot 'sat-time.txt' using 2:1 with points pt 7 ps 1 lc rgb 'blue' notitle, \
    x with line lt 1 lc rgb 'black' notitle

