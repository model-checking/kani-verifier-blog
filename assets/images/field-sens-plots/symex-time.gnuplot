set term pngcairo size 400, 400
set output 'symex-time.png'
set logscale xy
set xlabel 'no field-sens'
set ylabel 'field-sens'
set xrange [1:100]
set yrange [1:100]
set size ratio 1
set title 'Symex time (s)'
plot 'symex-time.txt' using 2:1 with points pt 7 ps 1 lc rgb 'blue' notitle, \
    x with line lt 1 lc rgb 'black' notitle

