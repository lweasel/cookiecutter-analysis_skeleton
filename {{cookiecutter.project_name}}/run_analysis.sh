#!/bin/bash


function cleanup {
  echo "Removing tmp"
  #not implement
}

trap cleanup EXIT
trap "exit" INT TERM
trap "kill 0" EXIT

set -o nounset
set -o errexit
set -o xtrace

source functions.sh

MAIN_DIR=${HOME}/{{cookiecutter.projects_base}}/{{cookiecutter.project_name}}
DATA_DIR=${MAIN_DIR}/data
RNASEQ_DIR=${DATA_DIR}/rnaseq
PICARD_DATA=${DATA_DIR}/picard

REGION_MATRIX_DIR=/opt/region_matrix
WIGGLETOOLS=/opt/WiggleTools/bin/wiggletools

RESULTS_DIR=${MAIN_DIR}/results

QC_DIR=${RESULTS_DIR}/fastqc
MAPPING_DIR=${RESULTS_DIR}/mapped_reads
FINAL_BAM_DIR=${RESULTS_DIR}/final_bams
COUNTS_DIR=${RESULTS_DIR}/read_counts
SALMON_QUANT_DIR=${RESULTS_DIR}/salmon_quant
KALLISTO_QUANT_DIR=${RESULTS_DIR}/kallisto_quant
DIFF_EXPR_DIR=${RESULTS_DIR}/differential_expression
PICARD_DIR=${RESULTS_DIR}/alignment_metrics

SARGASSO_RESULTS_DIR=${RESULTS_DIR}/sargasso
FILTERED_DIR=${SARGASSO_RESULTS_DIR}/filtered_reads

SPECIES=()
ENSEMBL_DIR=()
STAR_INDEX=()
GTF_FILE=()
SPECIES_PARA=()
REF_FLAT=()

{% for s in cookiecutter.species.split(' ') %}
SPECIES+=({{ s }})
ENSEMBL_DIR+=(${DATA_DIR}/{{ s }}_ensembl_{{cookiecutter.ensembl_version}})
STAR_INDEX+=(${DATA_DIR}/{{ s }}_ensembl_{{cookiecutter.ensembl_version}}/{{cookiecutter.assembly_names[s]}})
GTF_FILE+=(${DATA_DIR}/{{ s }}_ensembl_{{cookiecutter.ensembl_version}}/{{cookiecutter.gtf_files[s]}})
REF_FLAT+=(${PICARD_DATA}/{{ s }}/{{cookiecutter.rff_files[s]}})
SALMON_INDEX=(${DATA_DIR}/{{ s }}_ensembl_{{cookiecutter.ensembl_version}}/{{cookiecutter.salmon_index}})
KALLISTO_INDEX=(${DATA_DIR}/{{ s }}_ensembl_{{cookiecutter.ensembl_version}}/{{cookiecutter.kallisto_index}})
SPECIES_PARA+=("{{ s }} ${DATA_DIR}/{{ s }}_ensembl_{{cookiecutter.ensembl_version}}/{{cookiecutter.assembly_names[s]}}")
{% endfor %}


STAR_EXECUTABLE=STAR{{cookiecutter.star_version}}

NUM_THREADS_PER_SAMPLE={{cookiecutter.number_threads_per_sample}}
NUM_TOTAL_THREADS={{cookiecutter.number_total_threads}}
THREAD_USING=0
MEM_USING=0

qSVA="{{cookiecutter.qSVA}}"
SAMPLES="{{cookiecutter.rnaseq_samples}}"
PAIRED_END_READ="{{cookiecutter.paired_end_read}}"
USE_SARGASSO="{{cookiecutter.sargasso}}"
STRATEGY="{{cookiecutter.strategy}}"

{% if cookiecutter.sargasso == "yes" %}
#### Create Sargasso samples.tsv file
addSample2tsv ${MAIN_DIR}/sample.tsv {{ cookiecutter.rnaseq_samples_dir }} \
{{ cookiecutter.read1_identifier}} {{ cookiecutter.read2_identifier}} {{ cookiecutter.fastq_suffix }} \
{{ cookiecutter.paired_end_read}} {{cookiecutter.rnaseq_samples}}
{% endif %}


#### Create gene lengths CSV files
for i in ${!SPECIES[@]}; do
    get_gene_lengths <(tail -n +6 ${GTF_FILE[$i]}) > ${ENSEMBL_DIR[$i]}/gene_lengths.csv &
    # Construct transcript->gene mapping file for tximport
    awk '$3=="transcript" {print $14, $10}' ${GTF_FILE[$i]} | sed 's/"//g;s/;//g' > ${ENSEMBL_DIR[$i]}/tx2gene.tsv &
done
#wait

#### Perform QC on raw reads
#mkdir -p ${QC_DIR}
#
#for sample in ${SAMPLES}; do
#    output_dir=${QC_DIR}/${sample}
#    mkdir -p ${output_dir}
#    checkBusy
#    (zcat ${RNASEQ_DIR}/${sample}/*.{{cookiecutter.fastq_suffix}} | fastqc --outdir=${output_dir} stdin) &
#done
#wait $(jobs -p)

#### Perform QC on raw reads
mkdir -p ${QC_DIR}
echo -n ${SAMPLES} | xargs -t -d ' ' -n 1 -P ${NUM_TOTAL_THREADS} -I % bash -c \
"mkdir -p ${QC_DIR}/%; zcat ${RNASEQ_DIR}/%/*.{{cookiecutter.fastq_suffix}} | fastqc --outdir=${QC_DIR}/% stdin"



{% if cookiecutter.sargasso == "yes" %}
####map reads
#### Run Sargasso
species_separator --star-executable ${STAR_EXECUTABLE} --sambamba-sort-tmp-dir=${HOME}/tmp \
        --${STRATEGY} --num-threads-per-sample ${NUM_THREADS_PER_SAMPLE} \
        --num-total-threads ${NUM_TOTAL_THREADS} \
        ${SAMPLE_TSV} ${SARGASSO_RESULTS_DIR} ${SPECIES_PARA[@]}
cd ${RESULTS_DIR} && make &
wait $(jobs -p)


mkdir -p ${FINAL_BAM_DIR}
for species in ${!SPECIES[@]};do
    for sample in ${SAMPLES}; do
        checkBusy
        sambamba sort -t ${NUM_THREADS_PER_SAMPLE} -o ${FINAL_BAM_DIR}/${sample}.${SPECIES[$species]}.bam ${FILTERED_DIR}/${sample}.${SPECIES[$species]}_filtered.bam &
    done
######## NEED TEST WHICH IS BETTER IN THE NEXT PROJECT
#    for species in ${!SPECIES[@]};do
#        echo -n ${SAMPLES} | xargs -t -d ' ' -n 1 -P $(awk '{print int($1/$2)}' <<< "${NUM_TOTAL_THREADS} ${NUM_THREADS_PER_SAMPLE}") -I % bash -c \
#        "sambamba sort -t ${NUM_THREADS_PER_SAMPLE} -o ${FINAL_BAM_DIR}/%.${SPECIES[$species]}.bam ${FILTERED_DIR}/%.${SPECIES[$species]}_filtered.bam"
#    done
done
wait
{% else %}

##### Map reads
mkdir -p ${MAPPING_DIR}
mkdir -p ${FINAL_BAM_DIR}

for sample in ${SAMPLES}; do
    checkBusy
    {% if cookiecutter.paired_end_read == "yes" %}
    map_reads ${sample} ${STAR_INDEX} ${NUM_THREADS_PER_SAMPLE} $(listFiles , ${RNASEQ_DIR}/${sample}/*{{cookiecutter.read1_identifier}}.{{cookiecutter.fastq_suffix}}) $(listFiles , ${RNASEQ_DIR}/${sample}/*{{cookiecutter.read2_identifier}}.{{cookiecutter.fastq_suffix}}) ${MAPPING_DIR} &
    {% else %}
    map_reads ${sample} ${STAR_INDEX} ${NUM_THREADS_PER_SAMPLE} $(listFiles , ${RNASEQ_DIR}/${sample}/*.{{cookiecutter.fastq_suffix}}) "" ${MAPPING_DIR} &
    {% endif %}
done
wait

######## NEED TEST WHICH IS BETTER IN THE NEXT PROJECT
#{% if cookiecutter.sargasso == "yes" %}
#echo -n ${SAMPLES} | xargs -t -d ' ' -n 1 -P $(awk '{print int($1/$2)}' <<< "${NUM_TOTAL_THREADS} ${NUM_THREADS_PER_SAMPLE}") -I % bash -c \
#"map_reads % ${STAR_INDEX} ${NUM_THREADS_PER_SAMPLE} $(listFiles , ${RNASEQ_DIR}/%/*{{cookiecutter.read1_identifier}}.{{cookiecutter.fastq_suffix}}) $(listFiles , ${RNASEQ_DIR}/%/*{{cookiecutter.read2_identifier}}.{{cookiecutter.fastq_suffix}}) ${MAPPING_DIR}"
#{% else %}
#echo -n ${SAMPLES} | xargs -t -d ' ' -n 1 -P $(awk '{print int($1/$2)}' <<< "${NUM_TOTAL_THREADS} ${NUM_THREADS_PER_SAMPLE}") -I % bash -c \
#"map_reads % ${STAR_INDEX} ${NUM_THREADS_PER_SAMPLE} $(listFiles , ${RNASEQ_DIR}/%/*.{{cookiecutter.fastq_suffix}}) "" ${MAPPING_DIR}"
#{% endif %}

for species in ${!SPECIES[@]};do
    for sample in ${SAMPLES}; do
        ln -s ${MAPPING_DIR}/${sample}.sorted.bam ${FINAL_BAM_DIR}/${sample}.${SPECIES[$species]}.bam
    done
done

{% endif %}




#### Run Picard alignment metrics summary
for species in ${!SPECIES[@]};do
    mkdir -p ${PICARD_DIR}/${SPECIES[$species]}
    grep rRNA ${GTF_FILE[$species]}  | cut -s -f 1,4,5,7,9 > ${PICARD_DATA}/${SPECIES[$species]}/intervalListBody.txt
    for sample in ${SAMPLES}; do
        checkBusy
        picard_rnaseq_metrics ${sample} ${FINAL_BAM_DIR}/${sample}.${SPECIES[$species]}.bam ${PICARD_DIR}/${SPECIES[$species]} ${REF_FLAT[$species]} ${PICARD_DATA}/${SPECIES[$species]} &
    done
######## NEED TEST WHICH IS BETTER IN THE NEXT PROJECT
#    echo -n ${SAMPLES} | xargs -t -d ' ' -n 1 -P ${NUM_TOTAL_THREADS} -I % bash -c \
#    "source functions.sh; picard_rnaseq_metrics % ${FINAL_BAM_DIR}/%.${SPECIES[$species]}.bam ${PICARD_DIR}/${SPECIES[$species]} ${REF_FLAT[$species]} ${PICARD_DATA}/${SPECIES[$species]}"
done
wait



##### Count reads
mkdir -p ${COUNTS_DIR}

first_sample="TRUE"

for sample in ${SAMPLES}; do
    [[ "${first_sample}" == "FALSE" ]] || {
        first_sample="FALSE"
        for i in ${!SPECIES[@]}; do
            count_reads_for_features_strand_test ${NUM_THREADS_PER_SAMPLE} ${GTF_FILE[$i]} ${FINAL_BAM_DIR}/${sample}.${SPECIES[$species]}.bam ${COUNTS_DIR}/strand_test.${sample}.${SPECIES[$i]}.counts
        done
    }

    for i in ${!SPECIES[@]}; do
        checkBusy
        count_reads_for_features ${NUM_THREADS_PER_SAMPLE} ${GTF_FILE[$i]} ${FINAL_BAM_DIR}/${sample}.${SPECIES[$species]}.bam ${COUNTS_DIR}/${sample}.${SPECIES[$i]}.counts &
    done
done
wait $(jobs -p)

##### Pre-processing for qSVA
if [ "${qSVA}" != "no" ]; then
    for sample in ${SAMPLES}; do
        for species in ${!SPECIES[@]}; do
            checkBusy
            sambamba index -t ${NUM_THREADS_PER_SAMPLE} ${FINAL_BAM_DIR}/${sample}.${SPECIES[$species]}.bam &
        done
    done
    wait

    for sample in ${SAMPLES}; do
        for species in ${!SPECIES[@]}; do
            checkBusy
            python ${REGION_MATRIX_DIR}/region_matrix.py \
                    --regions ${REGION_MATRIX_DIR}/sorted_polyA_degradation_regions_v2.bed \
                    --bams ${FINAL_BAM_DIR}/${sample}.${SPECIES[$species]}.bam \
                    --wiggletools ${WIGGLETOOLS} > ${COUNTS_DIR}/${sample}.${SPECIES[$species]}.dm.tsv &
        done
    done
    wait
fi




###### Quantify transcript expression with Salmon
#mkdir -p ${SALMON_QUANT_DIR}
#
#for sample in ${SAMPLES}; do
#    checkBusy
#    if [ $PAIRED_END_READ = "yes" ]; then
#        salmon quant -i ${SALMON_INDEX} -l A -1 $(listFiles ' ' ${RNASEQ_DIR}/${sample}/*{{cookiecutter.read1_identifier}}.{{cookiecutter.fastq_suffix}}) -2 $(listFiles ' ' ${RNASEQ_DIR}/${sample}/*{{cookiecutter.read2_identifier}}.{{cookiecutter.fastq_suffix}}) -o ${SALMON_QUANT_DIR}/${sample} --seqBias --gcBias -p ${NUM_THREADS_PER_SAMPLE} -g ${GTF_FILE} &
#    else
#        salmon quant -i ${SALMON_INDEX} -l A -r $(listFiles ' ' ${RNASEQ_DIR}/${sample}/*.{{cookiecutter.fastq_suffix}}) -o ${SALMON_QUANT_DIR}/${sample} --seqBias --gcBias -p ${NUM_THREADS_PER_SAMPLE} -g ${GTF_FILE} &
#   fi
#done
#
###### Quantify transcript expression with Kallisto
#mkdir -p ${KALLISTO_QUANT_DIR}
#
#for sample in ${SAMPLES}; do
#    checkBusy
#    if [ $PAIRED_END_READ = "yes" ]; then
#        kallisto quant -i ${KALLISTO_INDEX} -o ${KALLISTO_QUANT_DIR}/${sample} --bias --rf-stranded -t ${NUM_THREADS_PER_SAMPLE} $(ls -1 ${RNASEQ_DIR}/${sample}/*{{cookiecutter.read1_identifier}}.{{cookiecutter.fastq_suffix}} | sed -r 's/(.*)/\1 \1/' | sed -r 's/(.* .*){{cookiecutter.read1_identifier}}.{{cookiecutter.fastq_suffix}}/\1{{cookiecutter.read2_identifier}}.{{cookiecutter.fastq_suffix}}/' | tr '\n' ' ') &
#    else
#        kallisto quant -i ${KALLISTO_INDEX} -o ${KALLISTO_QUANT_DIR}/${sample} --bias --single -t ${NUM_THREADS_PER_SAMPLE} $(ls -1 ${RNASEQ_DIR}/${sample}/*.{{cookiecutter.fastq_suffix}} ) &
#    fi
#done
#wait

##### Gather all QC data
multiqc -d -f -m featureCounts -m star -m fastqc -m salmon -m kallisto -m sargasso ${RESULTS_DIR}

##### Perform differential expression
mkdir -p ${DIFF_EXPR_DIR}/go
mkdir -p ${DIFF_EXPR_DIR}/graphs
mkdir -p ${DIFF_EXPR_DIR}/gsa

exit;

Rscript diff_expr.R &
Rscript diff_expr_tx.R &
Rscript rMATS.R &

wait

for de_results in ${DIFF_EXPR_DIR}/*.csv; do
    clean_de_results ${de_results}
done
