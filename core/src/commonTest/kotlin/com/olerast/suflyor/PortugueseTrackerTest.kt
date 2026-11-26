package com.olerast.suflyor

import com.olerast.suflyor.doc.Paragraph
import com.olerast.suflyor.doc.ScriptDocument
import com.olerast.suflyor.script.ScriptLayout
import com.olerast.suflyor.script.ScriptModel
import com.olerast.suflyor.script.SpeechLang
import com.olerast.suflyor.script.WordNorm
import com.olerast.suflyor.track.ScriptTracker
import kotlin.test.Test

/** Brazilian Portuguese following: accents, contractions, hyphens, numbers, fillers, skips, retakes, a long passage. */
class PortugueseTrackerTest {
    private val pt = SpeechLang.PT

    private fun doc(vararg lines: String) = ScriptDocument("t", "test", lines.map { Paragraph(it) })

    private fun build(vararg lines: String): ScriptModel = ScriptLayout.build(doc(*lines), phraseMode = true, lang = pt)

    private class Run(val tracker: ScriptTracker, val trail: List<Int>, val model: ScriptModel) {
        val position get() = tracker.position
        val spoken get() = model.spokenTokens
    }

    /** Feeds [heard] word by word as a growing hypothesis; the trail is the position after each word. */
    private fun hear(
        m: ScriptModel,
        heard: String,
        tracker: ScriptTracker = ScriptTracker(m.tokens, m.lang),
        history: MutableList<String> = mutableListOf(),
    ): Run {
        val trail = mutableListOf<Int>()
        for (w in pt.words(heard)) {
            history += w
            tracker.onHypothesis(history.takeLast(pt.history))
            trail += tracker.position
        }
        return Run(tracker, trail, m)
    }

    private fun read(script: String, heard: String): Run = hear(build(script), heard)

    private fun assertFinishes(script: String, heard: String) {
        val r = read(script, heard)
        assertTrue("position ${r.position} of ${r.spoken}: $heard", r.position >= r.spoken - 1)
    }

    // --- language and normalization ---

    @Test
    fun detectsPortugueseNotSpanish() {
        fun detect(text: String) = SpeechLang.detect(doc(text))
        assertEquals(SpeechLang.PT, detect("Olá pessoal, hoje eu vou mostrar como a gente grava um vídeo com o celular, sem gastar quase nada."))
        assertEquals(SpeechLang.PT, detect("Você não precisa de equipamento caro para gravar; o áudio limpo faz toda a diferença."))
        assertEquals(SpeechLang.PT, detect("Eles disseram que não era possível, mas nós fizemos mesmo assim e ficamos muito felizes."))
        assertEquals(SpeechLang.ES, detect("Hola amigos, hoy les voy a mostrar cómo grabar un video con el celular, sin gastar casi nada."))
        assertEquals(SpeechLang.PT, SpeechLang.fromCode("pt"))
        assertEquals("pt", pt.code)
    }

    @Test
    fun normalizesAccentsCedillaAndPunctuation() {
        assertEquals("coração", WordNorm.PT.normalizeWord("Coração,"))
        assertEquals("ação", WordNorm.PT.normalizeWord("AÇÃO"))
        assertEquals(listOf("não", "é", "você"), pt.words("Não... é você?"))
        // Decomposed accents equal the composed form.
        assertEquals("ação", WordNorm.PT.normalizeWord("ação"))
        assertEquals(listOf("fazê", "lo", "disse", "me", "guarda", "chuva"), pt.words("fazê-lo, disse-me, guarda-chuva"))
        assertEquals(listOf("d", "água"), pt.words("d'água"))
    }

    @Test
    fun accentFoldingMatches() {
        for ((a, b) in listOf("você" to "voce", "não" to "nao", "ação" to "acao", "são" to "sao", "coração" to "coracao")) {
            assertTrue("$a/$b", pt.similarity(a, b) >= ScriptTracker.MATCH_SIM)
        }
        for ((a, b) in listOf("gato" to "carro", "ele" to "ela", "mesa" to "janela")) {
            assertTrue("$a/$b", pt.similarity(a, b) < ScriptTracker.MATCH_SIM)
        }
    }

    @Test
    fun weightsAndAbbreviations() {
        assertEquals(0f, pt.weight("2026", false))
        assertEquals(0.2f, pt.weight("do", false))
        assertEquals(0.2f, pt.weight("não", false))
        assertEquals(0.6f, pt.weight("sol", false))
        assertEquals(1f, pt.weight("câmera", false))
        val pack = WordNorm.PT
        for (a in listOf("Sr.", "Dra.", "Prof.", "nº", "etc.", "M.")) assertTrue(a, pack.isAbbreviation(a))
        assertFalse(pack.isAbbreviation("casa."))
        // "Dr." is a word of the script, not the end of a sentence.
        val m = build("O Dr. Silva chegou cedo.")
        assertEquals(listOf("o", "dr", "silva", "chegou", "cedo"), m.tokens.filter { it.spoken }.map { it.norm })
    }

    // --- accents, contractions, hyphens ---

    @Test
    fun followsRecognizerWithoutAccents() {
        assertFinishes(
            "Você não tem ação nenhuma, mas a gente também está aqui.",
            "voce nao tem acao nenhuma mas a gente tambem esta aqui",
        )
    }

    @Test
    fun followsRecognizerWithExtraAccents() {
        assertFinishes("Voce nao precisa de camera cara para gravar.", "você não precisa de câmera cara para gravar")
    }

    @Test
    fun contractionsAndCrase() {
        val script = "Fomos à praia do Rio e passamos no mercado da vila. Falei àquele homem pelo telefone, pela manhã."
        assertFinishes(script, "fomos à praia do rio e passamos no mercado da vila falei àquele homem pelo telefone pela manhã")
        // The recognizer may print the crase without the accent.
        assertFinishes(script, "fomos a praia do rio e passamos no mercado da vila falei aquele homem pelo telefone pela manha")
    }

    @Test
    fun hyphenAndEnclisis() {
        val script = "Quero fazê-lo hoje. Ele disse-me que o guarda-chuva está no carro, e vê-se bem a cidade."
        assertFinishes(script, "quero fazê lo hoje ele disse me que o guarda chuva está no carro e vê se bem a cidade")
        // The recognizer may join the parts and drop the accents.
        assertFinishes(script, "quero fazelo hoje ele disse me que o guardachuva esta no carro e ve se bem a cidade")
    }

    // --- numbers ---

    @Test
    fun digitsInScriptSpokenAsWords() {
        assertFinishes(
            "Em 2026 vamos lançar 3 novos produtos para o mercado brasileiro.",
            "em dois mil e vinte e seis vamos lançar três novos produtos para o mercado brasileiro",
        )
    }

    @Test
    fun percentInScriptSpokenAsWords() {
        assertFinishes(
            "As vendas cresceram 15% neste trimestre, segundo a nossa equipe.",
            "as vendas cresceram quinze por cento neste trimestre segundo a nossa equipe",
        )
    }

    @Test
    fun decimalsAndThousandsInScript() {
        assertFinishes(
            "O preço caiu para 1.250 reais e depois para 9,5 mil na promoção.",
            "o preço caiu para mil duzentos e cinquenta reais e depois para nove vírgula cinco mil na promoção",
        )
    }

    @Test
    fun digitsHeardForWordsInScript() {
        assertFinishes(
            "Chegamos às três da tarde e ficamos até as dez da noite.",
            "chegamos às 3 da tarde e ficamos até as 10 da noite",
        )
    }

    @Test
    fun numbersWrittenAsWordsInScript() {
        assertFinishes(
            "Foram vinte e cinco pessoas na sala, e dois deles ficaram em pé.",
            "foram vinte e cinco pessoas na sala e dois deles ficaram em pé",
        )
    }

    // --- abbreviations: the normalizer does not expand them, the tracker still gets through ---

    @Test
    fun abbreviationsReadInFullStillFinish() {
        val script = "Falei com o Dr. Silva e a Sra. Costa ontem na reunião do projeto."
        assertFinishes(script, "falei com o doutor silva e a senhora costa ontem na reunião do projeto")
        assertFinishes(script, "falei com o dr silva e a sra costa ontem na reunião do projeto")
        assertFinishes(
            "O pedido nº 45 chegou ontem na loja da avenida central.",
            "o pedido número quarenta e cinco chegou ontem na loja da avenida central",
        )
        assertFinishes(
            "A Prof. Maria explicou o assunto para toda a turma da escola.",
            "a professora maria explicou o assunto para toda a turma da escola",
        )
    }

    @Test
    fun ordinalsMoneyAndTimesWrittenWithNumerals() {
        assertFinishes(
            "Ele nasceu em 1º de maio e ganhou o 2º lugar na prova de natação.",
            "ele nasceu em primeiro de maio e ganhou o segundo lugar na prova de natação",
        )
        assertFinishes(
            "Compre agora por R$ 50 e leve também um brinde especial para casa.",
            "compre agora por cinquenta reais e leve também um brinde especial para casa",
        )
        assertFinishes(
            "Às 14h30 começa a transmissão ao vivo do evento principal.",
            "às quatorze e trinta começa a transmissão ao vivo do evento principal",
        )
    }

    @Test
    fun colloquialContractionsAndSpellingVariants() {
        assertFinishes(
            "Ele me disse que pra você tá tudo certo e que a gente vai nessa.",
            "ele me disse que para você está tudo certo e que a gente vai nessa",
        )
        assertFinishes("Moro em São Paulo, na zona sul, perto do parque e da escola.", "moro em sao paulo na zona sul perto do parque e da escola")
    }

    // --- fillers and hesitations ---

    @Test
    fun hesitationsDoNotMakeTheTrackerJump() {
        val m = build("A gente vai começar pela parte mais simples do projeto, que é a configuração inicial do ambiente.")
        val history = mutableListOf<String>()
        val a = hear(m, "a gente vai começar pela parte", history = history)
        val before = a.position
        val fill = hear(m, "é hum né tipo ah hmm", a.tracker, history)
        assertTrue("moved: ${fill.trail} (was $before)", fill.trail.all { it <= before + 1 })
        val done = hear(m, "mais simples do projeto que é a configuração inicial do ambiente", a.tracker, history)
        assertTrue("position ${done.position} of ${done.spoken}", done.position >= done.spoken - 1)
    }

    @Test
    fun fillersInsideTheReadingAreIgnored() {
        assertFinishes(
            "Hoje vamos falar sobre três erros comuns que atrapalham quem está começando a gravar.",
            "hoje vamos é falar sobre hum três erros né comuns que tipo atrapalham ah quem está começando a gravar",
        )
    }

    @Test
    fun softFillersThatAreScriptWordsStillMatch() {
        // "então", "tipo", "assim", "bom" are real words: they count when the script has them.
        assertFinishes(
            "Então, o resultado ficou bom, tipo assim: rápido e barato.",
            "então o resultado ficou bom tipo assim rápido e barato",
        )
    }

    // --- skips, repeats, improvisation ---

    private val short = "Primeiro a gente escolhe o lugar da gravação. Depois ajusta a luz da janela e testa o microfone. " +
        "Por fim, respira fundo e começa a falar com calma, olhando para a lente."

    @Test
    fun skippedWordIsTolerated() {
        assertFinishes(
            short,
            "primeiro a gente escolhe lugar da gravação depois ajusta a luz da janela e testa o microfone por fim respira fundo e começa falar com calma olhando para a lente",
        )
    }

    @Test
    fun repeatedWordDoesNotMoveBackOrStall() {
        val r = read(
            short,
            "primeiro a a gente gente escolhe o o lugar da gravação depois ajusta a luz da janela e testa o microfone por fim respira fundo e começa a falar com calma olhando para a lente",
        )
        assertTrue("position ${r.position} of ${r.spoken}", r.position >= r.spoken - 1)
        assertTrue("went back: ${r.trail}", r.trail.zipWithNext().all { (a, b) -> b >= a })
    }

    @Test
    fun resumesAfterOffScriptSentence() {
        val m = build(short)
        val history = mutableListOf<String>()
        val first = hear(m, "primeiro a gente escolhe o lugar da gravação depois ajusta a luz", history = history)
        val before = first.position
        val aside = hear(m, "desculpa gente deixa eu tomar um gole de água rapidinho", first.tracker, history)
        assertTrue("jumped: ${aside.trail} (was $before)", aside.trail.all { it <= before + 1 })
        val rest = hear(
            m,
            "da janela e testa o microfone por fim respira fundo e começa a falar com calma olhando para a lente",
            first.tracker, history,
        )
        assertTrue("position ${rest.position} of ${rest.spoken}", rest.position >= rest.spoken - 1)
    }

    @Test
    fun retakeOfTheLineJustRead() {
        val m = build(short)
        val history = mutableListOf<String>()
        val a = hear(m, "primeiro a gente escolhe o lugar da gravação depois ajusta a luz da janela e testa o microfone", history = history)
        val atEnd = a.position
        val b = hear(m, "depois ajusta a luz da janela e testa o microfone", a.tracker, history)
        assertEquals(atEnd, b.position)
        val c = hear(m, "por fim respira fundo e começa a falar com calma olhando para a lente", a.tracker, history)
        assertTrue("position ${c.position} of ${c.spoken}", c.position >= c.spoken - 1)
    }

    @Test
    fun scatteredCommonWordsDoNotJump() {
        val m = build(short)
        val history = mutableListOf<String>()
        val a = hear(m, "primeiro a gente escolhe o lugar da gravação", history = history)
        val before = a.position
        val b = hear(m, "o e da", a.tracker, history)
        assertTrue("jumped: ${b.trail} (was $before)", b.trail.all { it <= before + 1 })
    }

    // --- long passage, in partial and final chunks ---

    private val passage = listOf(
        "Quando eu comecei a gravar vídeos, achava que bastava ligar a câmera e falar. Em poucos minutos percebi que não era tão simples assim. " +
            "O som saía abafado, a luz da sala deixava meu rosto escuro e eu esquecia metade do que queria dizer.",
        "Foi então que decidi montar um roteiro. Escrevi o texto inteiro em uma folha, li em voz alta duas ou três vezes e cortei tudo o que soava artificial. " +
            "Uma frase longa demais vira um tropeço na hora da gravação, e ninguém gosta de assistir a alguém perdido no próprio discurso.",
        "Depois do roteiro, vem o ambiente. Procure um lugar silencioso, longe da rua e do ventilador. Sente perto da janela, de frente para a luz, " +
            "e deixe o celular na altura dos olhos. Parece detalhe, mas a imagem melhora muito com esses pequenos cuidados.",
        "O teleprompter entra justamente aqui. Com o texto na tela, você olha para a lente e continua lendo sem perder o fio da meada. " +
            "Se errar uma palavra, não pare: respire, volte ao começo da frase e siga em frente. O público quase nunca percebe.",
        "No início, a leitura soa dura, quase robótica. Com o tempo, você aprende a marcar as pausas, a sorrir nos momentos certos e a dar ênfase às ideias principais. " +
            "Grave um trecho curto, assista com atenção e anote o que pode melhorar na próxima tentativa.",
        "Antes de gravar de verdade, faço sempre um teste rápido. Falo uma frase, escuto o resultado e confiro se a voz está clara, sem chiado nem eco. " +
            "Se algo soar estranho, mudo de lugar ou fecho a janela, e só então começo a sério.",
        "Em 2026 eu gravei mais de 120 vídeos, e o ganho de qualidade foi enorme. A confiança cresce a cada novo arquivo, e o medo de errar diminui aos poucos. " +
            "No fim das contas, o segredo é praticar, ser gentil consigo mesmo e nunca esperar a perfeição logo na primeira tentativa.",
    )

    /** What the recognizer prints for [text]: lower case, no punctuation, digits as words, some words without accents. */
    private fun asr(text: String): String = text
        .replace("2026", "dois mil e vinte e seis").replace("120", "cento e vinte")
        .lowercase().replace(Regex("[.,:;!?]"), "")
        .replace("não", "nao").replace("você", "voce")

    @Test
    fun longPassageReadInPartialsAndFinals() {
        val m = build(*passage.toTypedArray())
        assertTrue("passage has ${m.spokenTokens} words", m.spokenTokens >= 300)
        val tracker = ScriptTracker(m.tokens, m.lang)
        val history = mutableListOf<String>()
        var last = 0
        var peak = 0 // a one-word step back is tolerated
        for (para in passage) {
            // Utterances of 7 words: every word grows the partial, then the final repeats it.
            for (chunk in pt.words(asr(para)).chunked(7)) {
                for (w in chunk) {
                    history += w
                    tracker.onHypothesis(history.takeLast(pt.history))
                    assertTrue("went back at '$w': ${tracker.position} < $peak", tracker.position >= peak - 1)
                    last = tracker.position
                    peak = maxOf(peak, last)
                }
                tracker.onHypothesis(history.takeLast(pt.history))
                assertEquals(last, tracker.position)
            }
        }
        assertTrue("position ${tracker.position} of ${m.spokenTokens}", tracker.position >= m.spokenTokens - 2)
    }

    @Test
    fun longPassageWithRecognizerNoise() {
        val m = build(*passage.toTypedArray())
        val tracker = ScriptTracker(m.tokens, m.lang)
        val history = mutableListOf<String>()
        pt.words(asr(passage.joinToString(" "))).forEachIndexed { i, w ->
            if (i % 11 == 5) return@forEachIndexed // dropped word
            history += w
            if (i % 17 == 8) history += "né"
            if (i % 23 == 3) history += "hum"
            tracker.onHypothesis(history.takeLast(pt.history))
        }
        assertTrue("position ${tracker.position} of ${m.spokenTokens}", tracker.position >= m.spokenTokens - 3)
    }
}
