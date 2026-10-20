package com.example.lien

import org.junit.Assert.assertEquals
import org.junit.Test

class PlaceholderContentTest {
    @Test
    fun titleIdentifiesLienInJapanese() {
        assertEquals("Lien（リアン）", PlaceholderContent.title)
    }

    @Test
    fun taglineDescribesOneSharedPromise() {
        assertEquals("ふたりで、ひとつの約束を。", PlaceholderContent.tagline)
    }

    @Test
    fun messageMakesPlaceholderStatusExplicit() {
        assertEquals("Android版は準備中です。", PlaceholderContent.message)
    }
}
