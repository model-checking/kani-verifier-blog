set term pngcairo size 400, 400
set output 'symex-steps.png'
set logscale xy
set xlabel 'no field-sens'
set ylabel 'field-sens'
set xrange [900:1000000]
set yrange [900:1000000]
set size ratio 1
set title 'Symex steps'
plot 'symex-steps.txt' using 2:1 with points pt 7 ps 1 lc rgb 'blue' notitle, \
    x with line lt 1 lc rgb 'black' notitle

