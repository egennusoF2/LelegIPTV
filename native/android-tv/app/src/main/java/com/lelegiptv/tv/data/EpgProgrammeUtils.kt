package com.lelegiptv.tv.data

fun dedupeEpgProgrammes(programmes: List<EpgProgramme>): List<EpgProgramme> =
    programmes
        .distinctBy { "${it.startTimeMillis}|${it.endTimeMillis}|${it.title.lowercase()}" }
        .sortedBy(EpgProgramme::startTimeMillis)

fun programmesForDay(
    programmes: List<EpgProgramme>,
    dayStart: Long,
    dayEnd: Long,
): List<EpgProgramme> =
    dedupeEpgProgrammes(
        programmes.filter { programme ->
            programme.startTimeMillis in dayStart until dayEnd
        },
    )

fun epgProgrammeKey(programme: EpgProgramme): String =
    "${programme.startTimeMillis}_${programme.endTimeMillis}_${programme.title.hashCode()}"

fun EpgProgramme.isLiveAt(nowMillis: Long): Boolean =
    startTimeMillis <= nowMillis && nowMillis < endTimeMillis

fun dayBoundary(referenceMillis: Long, dayOffset: Int): Long =
    java.util.Calendar.getInstance().run {
        timeInMillis = referenceMillis
        add(java.util.Calendar.DAY_OF_YEAR, dayOffset)
        set(java.util.Calendar.HOUR_OF_DAY, 0)
        set(java.util.Calendar.MINUTE, 0)
        set(java.util.Calendar.SECOND, 0)
        set(java.util.Calendar.MILLISECOND, 0)
        timeInMillis
    }

fun nextDayBoundary(dayStart: Long): Long =
    java.util.Calendar.getInstance().run {
        timeInMillis = dayStart
        add(java.util.Calendar.DAY_OF_YEAR, 1)
        timeInMillis
    }

fun dayCoversProgrammes(programmes: List<EpgProgramme>, dayStart: Long, dayEnd: Long): Boolean =
    programmes.any { it.startTimeMillis in dayStart until dayEnd }
