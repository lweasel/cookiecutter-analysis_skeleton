#!/bin/bash

STAR=STAR{{cookiecutter.star_version}}
FEATURE_COUNTS=featureCounts{{cookiecutter.featurecounts_version}}
PICARD=/opt/picard-tools-{{cookiecutter.picard_version}}/picard.jar

function listFiles {
    DELIMITER=$1
    shift
    FILES=$@

    OUTPUT=$(ls -1 $FILES | tr '\n' "${DELIMITER}")
    echo ${OUTPUT%$DELIMITER}
}

function map_reads {
    SAMPLE=$1
    INDEX_DIR=$2
    NUM_THREADS=$3
    READ_1_FILES=$4
    READ_2_FILES=$5
    OUTPUT_DIR=$6

    star_tmp=${SAMPLE}.tmp
    mkdir ${star_tmp}

    if [ -z "$READ_2_FILES" ]
    then
        #if read_2 files is empty, the input is single end read
        read_files_opt="--readFilesIn ${READ_1_FILES}"
    else
        read_files_opt="--readFilesIn ${READ_1_FILES} ${READ_2_FILES}"
    fi

    ${STAR} --runThreadN ${NUM_THREADS} --genomeDir ${INDEX_DIR} --outFileNamePrefix ${star_tmp}/star --outSAMstrandField intronMotif --outSAMtype BAM SortedByCoordinate Unsorted --readFilesCommand zcat ${read_files_opt}

    mv ${star_tmp}/starAligned.out.bam ${OUTPUT_DIR}/${SAMPLE}.bam
    mv ${star_tmp}/starAligned.sortedByCoord.out.bam ${OUTPUT_DIR}/${SAMPLE}.sorted.bam
    mv ${star_tmp}/starLog.final.out ${OUTPUT_DIR}/${SAMPLE}.log.out

    rm -rf ${star_tmp}
}

function picard_rnaseq_metrics {
  SAMPLE=$1
  INPUT_DIR=$2
  OUTPUT_DIR=$3
  REF_FLAT=$4
  RIBOSOMAL_DIR=$5

  sambamba view -H ${INPUT_DIR}/${SAMPLE}.sorted.bam > ${RIBOSOMAL_DIR}/${SAMPLE}_header.txt
  cat ${RIBOSOMAL_DIR}/${SAMPLE}_header.txt ${RIBOSOMAL_DIR}/intervalListBody.txt > ${RIBOSOMAL_DIR}/${SAMPLE}.txt

  java -jar ${PICARD} CollectRnaSeqMetrics I=${INPUT_DIR}/${SAMPLE}.sorted.bam O=${OUTPUT_DIR}/${SAMPLE}.txt REF_FLAT=${REF_FLAT} STRAND=SECOND_READ_TRANSCRIPTION_STRAND RIBOSOMAL_INTERVALS=${RIBOSOMAL_DIR}/${SAMPLE}.txt
}

function count_reads_for_features {
    NUM_THREADS=$1
    FEATURES_GTF=$2
    BAM_FILE=$3
    COUNTS_OUTPUT_FILE=$4

    counts_tmp=.$(basename "${BAM_FILE}").counts_tmp

    ${FEATURE_COUNTS} -T ${NUM_THREADS} -p -a ${FEATURES_GTF} -o ${counts_tmp} -s 2 ${BAM_FILE}
    tail -n +3 ${counts_tmp} | cut -f 1,7 > ${COUNTS_OUTPUT_FILE}

    rm ${counts_tmp}
    mv ${counts_tmp}.summary ${COUNTS_OUTPUT_FILE}.summary
}

function count_reads_for_features_strand_test {
    NUM_THREADS=$1
    FEATURES_GTF=$2
    BAM_FILE=$3
    COUNTS_OUTPUT_FILE=$4

    counts_tmp=.$(basename "${BAM_FILE}").counts_tmp


    for i in 0 1 2; do
        ${FEATURE_COUNTS} -T ${NUM_THREADS} -p -a ${FEATURES_GTF} -o ${counts_tmp} -s $i ${BAM_FILE}
        tail -n +3 ${counts_tmp} | cut -f 1,7 > ${COUNTS_OUTPUT_FILE}.$i

        rm ${counts_tmp}
        mv ${counts_tmp}.summary ${COUNTS_OUTPUT_FILE}.$i.testsummary
    done
}

function clean_de_results {
    DE_RESULTS_FILE=$1

    sed -i "s/-Inf/'-Inf/g;s/,NA,/,,/g;s/,NA,/,,/g;s/,NA$/,/g" ${DE_RESULTS_FILE}
}

function isBusy {

MAX_MEM=$(cat /proc/meminfo | grep 'MemTotal'| awk '{print int($2/(1024^2))}')
ALLOW_MEM=$(echo ${MAX_MEM} | awk '{print int($1 * 0.8)}')
MAX_CORES=$(cat /proc/cpuinfo | grep processor | wc -l)
ALLOW_CORES=$(echo ${MAX_CORES} | awk '{print int($1 * 0.8)}')

    if [ "$(($THREAD_USING))" -ge "${NUM_TOTAL_THREADS}"  ] || [ "${MEM_USING}" -ge "${ALLOW_MEM}" ] \
     || [ "$((${THREAD_USING}+${NUM_THREADS_PER_SAMPLE}))"  -g "${NUM_TOTAL_THREADS}"  ]; then
        echo "yes"
    else
        echo "no"
    fi
}

function checkBusy {
     if [ "$(isBusy)" == "yes" ] ; then
#        echo "server busy, ${THREAD_USING}/${MAX_CORES} cores/ ${MEM_USING}G/${MAX_MEM} memory using... waiting for jobs: $(jobs -p) "
        wait $(jobs -p)
        THREAD_USING=0
        MEM_USING=0
    fi
    THREAD_USING=$((${THREAD_USING}+${NUM_THREADS_PER_SAMPLE}))
    MEM_USING=$((${MEM_USING}+30))
}