class AkinatorController < ApplicationController
    protect_from_forgery except: [:food]

    require 'uri'

    def index
        # Solutionsを取得
        @solutions = Solution.all
        # Questionsを取得
        @questions = Question.all
        # 空の配列を生成
        @features = {}
        @solutions.each do |s|
            s_features = []
            s.features.each do |f|
                s_features.push(f.value)
            end
            @features[s.name] = s_features
        end
        # feature.valuesが一致するs.nameをまとめるため、Setを準備
        set = Set.new(@features.values)
        unidentifiable_features = set.to_a
        @unidentifiable_solutions = []
        unidentifiable_features.each do |unidentifiable_feature|
            gathered_solutions = @features.select{|k,v| v == unidentifiable_feature}.keys
            if gathered_solutions.length > 1
                @unidentifiable_solutions.push(gathered_solutions)
            end
        end
    end
    
    def reply_content(event, messages)
        rep = client.reply_message(
          event['replyToken'],
          messages
        )
        logger.warn rep.read_body unless Net::HTTPOK === rep
        rep
    end

    def food
        # POSTリクエストは引数として受け取っており、request変数に入っている
        # POSTリクエスト(リクエスト行、ヘッダー、空白行、メッセージボディ)
        body = request.body.read

        # 署名を検証
        signature = request.env['HTTP_X_LINE_SIGNATURE']
        unless client.validate_signature(body, signature)
            return head :bad_request
        end

        # メッセージのtype,userId,message等の情報を連想配列でeventsに代入（json形式から連想配列にしている）
        events = client.parse_events_from(body)

        events.each do |event|

            # eventのsourceからuseridを取得し、user_idに代入
            user_id = event['source']['userId']
            # clientのget_profileメソッドの引数にuser_idを代入
            profile = client.get_profile(user_id)
            # json形式のresponseを連想配列に変換
            profile = JSON.parse(profile.read_body)
            p "Receives message:#{event.message['text']} from #{profile['displayName']}."

            case event
            when Line::Bot::Event::Message
                handle_message(event, user_id)
            end
        end
        head :ok
    end

    def akinator_handler(user_status, message)
        case user_status.status
        when "pending"
            handle_pending(user_status, message)
        when "asking"
            handle_asking(user_status, message)
        when "guessing"
            handle_guessing(user_status, message)
        when "resuming"
            handle_resuming(user_status, message)
        when "begging"
            handle_begging(user_status, message)
        when "registering"
            handle_registering(user_status, message)
        when "confirming"
            handle_confirming(user_status, message)
        end
    end

    def handle_message(event, user_id)
        # 途中終了するときの処理
        if event.message['text'] == "終了"
            reply_content = set_butten_template(altText: "また遊んでね！", title: "今回は終了しました。\nまた遊ぶときは「はじめる」をタップ！\n（「はじめる」してから最初の質問まで15秒ほどかかります。。。）", text: "はじめる")
            reply_content(event, reply_content)
            user_status = get_user_status(user_id)
            reset_status(user_status)
        else
            case event.type
            when Line::Bot::Event::MessageType::Text
                # 受け取ったメッセージの文字列をmessageに代入
                message = event.message['text']
                # UserStatusのインスタンスを引数user_idで照合して、存在しなかった場合作成して、返り値はUserStatusインスタンス
                user_status = get_user_status(user_id)
                # akinator_handler（メソッド）に引数user_status, messageを渡し、返り値は連想配列{}
                reply_content = akinator_handler(user_status, message)
                # reply_contentメソッドを呼び出し
                # Messaging APIでは各メッセージに応答トークンという識別子がある
                # reply_messageの引数はreplyTokenとtype:textのtext:内容
                reply_content(event, reply_content)
            end
        end
    end

    def get_user_status(user_id)
        # user_idを受け取り、UserStatusインスタンスを検索して、sessionに情報を保存
        user_status = UserStatus.find_by(user_id: user_id)
        # 照合して存在してない場合
        if user_status.nil?
            # UserStatusのstatusはモデルでカラムをenum型に定義し、defaultで0='pending'としておく
            user_status = UserStatus.create(user_id: user_id)
        end
        session[:user_status] = user_status
        return user_status
    end

    # 次の質問を選択する
    # progressはUserStatusのレコード
    # 返り値は、q_score_tableのfeature.valueが最小のQuestionインスタンス
    def select_next_question(progress)
        done_question_set = Set.new()
        # set型とは、重複した値を格納できない点や、
        # 添え字やキーなどの概念がなく、ユニークな要素である点、
        # 要素の順序を保持しない点などの特徴がある。
        progress.answers.each do |ans|
            p ans
            # これまでに回答したQuestionのidをsetにadd
            done_question_set.add(ans.question_id)
        end
        # set型をarrayに変換
        done_question_ids = done_question_set.to_a
        p "回答済み：#{done_question_ids}"
        # これまでに回答したQuestionを除くQuestionを取得し、配列で取得
        rest_questions = Question.where.not(id: done_question_ids).map(&:id)
        p "rest_questions: #{rest_questions}"

        if rest_questions.empty?
            return nil
        else
            q_score_table = {}
            # candidatesのfeaturesを導くquestion_id（重複なし）をリスト型にして、キーとして繰り返し代入し、valueは0.0としておく
            rest_questions.each do |q_id|
                q_score_table[q_id] = 0.0
            end
            p "q_score_table: #{q_score_table}"

            # N+1問題を解決するために、、、ゴリ押し。eager_loadでキャッシュ
            solutions = progress.solutions.eager_load(:features)
            # キャッシュしたsolutions
            solutions.each do |s|
                q_score_table.keys.each do |q_id|
                    # キャッシュしたsにリレーションのあるfeaturesをhashに!
                    features = s.features.map {|f| f.attributes}
                    # hashのfeatures
                    features.each do |f|
                        # hashなのでキーからvalueを持ってこれる
                        question_id = f['question_id']
                        if question_id == q_id
                            # q_score_tableのそれぞれのvalueにfeature.valueを足す
                            # 1.0（ハイ）と-1.0（イイエ）が混在するquestion（valueが0.0に近い）ということは、その質問の回答によって選択肢が多く絞り込まれる。
                            q_score_table[q_id] += f['value']
                        else
                            # rest_questionsのidにリレーションを持つ、featureが無い場合（そのquestionに対するfeatureがnilの場合）
                            q_score_table[q_id] += 0.0
                        end
                    end
                end
            end
            q_score_table.each do |key, value|
                # q_score_tableのvalueを絶対値に。valueが大きい→その質問に対して選択肢は似た回答を持つ→その質問をしてもあまり絞り込めない、となる連想配列が完成
                q_score_table[key] = value.abs
            end
            p ("[select_next_question] q_score_table=> #{q_score_table}")

            # 最も絶対値が小さいquestionということは、その質問の回答が分かれる→その質問の回答によって選択肢が多く絞り込まれる。
            # rubyのmin,maxは、hashの場合、x=>[key,value], y=>[key,value] hash.eachだと、|x, y|と書くと、x=>key, y=>valueなのに…
            next_q_id = q_score_table.key(q_score_table.values.min{|x, y| x <=> y})
            # Questionインスタンスのキーが、next_q_idに合致する行を取得。
            return Question.find(next_q_id)
        end

    end

    # UserStatusを更新してsave
    def save_status(user_status, new_status: nil, next_question: nil)
        if new_status
            # new_statusが存在する場合
            user_status.update(status: new_status)
        end
        if next_question
            # next_questionが存在する場合
            # user_status.progressとquestionはthrough: :latest_question
            user_status.progress.questions << next_question
        end
    end

    # UserStatusのstatusをリセットする
    def reset_status(user_status)
        # Answerテーブルのprogress_idレコードがUserのprogress.idと合致するAnswerテーブルの行を削除
        # つまり、今回のUserのAnswerを全て削除
        user_status.progress.answers.destroy_all
        # UserStatusのprogressを削除
        # つまり、今回のUserの経過状況を全て削除
        user_status.progress.destroy
        # 上記を削除したUserStatusをsave
        save_status(user_status, new_status: 'pending')
    end

    # 現の選択肢のスコアテーブル、引数はUserStatusのprogress
    # 返り値はvalueが小さい順の連想配列s_score_table
    def gen_solution_score_table(progress)
        s_score_table = {}
        solutions = progress.solutions.eager_load(:features)
        solutions.ids.each do |s_id|
            # solutionのスコアテーブルとして、Progressのcandidatesレコード（Solutionの行になる？）を繰り返しsに代入して、Solutionのidをキーに。
            # valueは全て0.0（select_next_questionと同じ手法）
            s_score_table[s_id] = 0.0
        end

        solutions.each do |s|
            # progressと関連付くanswersを繰り返しansに代入
            progress.answers.each do |ans|
                # キャッシュしたsにリレーションのあるfeaturesをhashに!
                features = s.features.map {|f| f.attributes}
                    features.each do |f|
                        question_id = f['question_id']
                        if question_id == ans.question_id
                            # s_score_tableのs.idのvalueに、ans.value（回答のvalue）×用意してあるFeatureのvalueの積を足す。（0.0 + 1.0 or -1.0)
                            # 回答のvalueと用意してあるFeatureのvalueが一致していれば、1.0、一致しなければ-1.0がs_score_tableのvalueとなる
                            s_score_table[s.id] += ans.value * f['value']
                        else
                            # rest_questionsのidにリレーションを持つ、featureが無い場合（そのquestionに対するfeatureがnilの場合）
                            s_score_table[s.id] += ans.value * 0.0
                        end
                    end
                
            end
        end
        # s_score_tableをvalueで昇順に並び替えて、ハッシュに戻す
        s_score_table = s_score_table.sort{|x, y| x[1]<=>y[1]}.to_h

        p ("s_score_table: #{s_score_table}")
        return s_score_table
    end

    # 候補群の平均以上の候補のみを取得、引数はs_score_table、返り値はSolutionインスタンスたち
    def update_candidates(s_score_table)
        # s_score_tableのvaluesを取得し合計と要素数から、平均値を取得
        score_mean = s_score_table.values.sum(0.0) / s_score_table.values.length
        s_ids = []
        s_score_table.each do |s_id, score|
            if score >= score_mean
                # s_score_tableのscoreがscore_mean以上の場合、そのs_idのSolutionの行を取得
                s_ids.push(s_id)
            end
        end
        return Solution.where(id: s_ids)
    end

    # 決定可能か判断、引数はs_score_table, old_s_score_table、返り値はboolen
    def can_decide(s_score_table, old_s_score_table)
        # s_score_tableのvaluesを取得し（この時点で配列化されている）、scoresに代入
        scores = s_score_table.values
        # scoresのlengthが1又は、scores[0]がscores[1]と異なる場合（つまり選択肢が一つの場合）又は、
        # s_score_tableのキーたちとold_s_score_tableのキーたちが一致する場合（つまりupdate_candidateしても選択肢が変わらない場合）はtrueを返す
        if scores.length == 1 || scores[0] != scores[1] || s_score_table.keys == old_s_score_table.keys
            return true
        else
            return false
        end
    end

    # AnswerをProgress、セッションにpush、引数はprogress, answer_msg
    def push_answer(progress, answer_msg)
        # Answerをcreateしてanswerに代入
        answer = Answer.create()
        # progress.latest_questionを、createしたanwerに関連づいたquestionに代入
        answer.question = progress.questions.find_by(id: progress.latest_questions.last.question_id)
        if answer_msg == "はい"
            # answer_msgが"はい"の場合、Answerのvalueに1.0を代入、
            answer.value = 1.0
        else
            # それ以外の場合-1.0を代入
            answer.value = -1.0
        end
        # progressのanswersにcreateしたanswerを追加する（answerにprogress_idが入る）
        progress.answers << answer
        # ProgressのanswersにAnswer(answer.question, answer.value)を追加
        session[:answer] = answer
    end

    # s_score_tableから、現在最もAnswerとFeatureが近いSolutionを取得、引数はs_score_table、返り値はSolutionインスタンス
    def guess_solution(s_score_table)
        # s_score_tableのvalueが最大値のs.idを取得し、該当のSolutionの行を取得
        return Solution.find(s_score_table.key(s_score_table.values.max{|x, y| x <=> y}))
    end

    # 正解の場合等に呼び出されるメソッド。正解の選択肢が見つかった場合、今回の回答は全てその正解の選択肢のfeatureと考えられる。
    # なので、今回の質問と回答が正解の選択肢のQuestion_id,Feature_valueとして保持されている場合は更新し、保持されていない場合は新規作成する。 
    def update_features(progress, true_solution: nil)
        if true_solution.present?
            # true_solutionがfalse,nil以外の場合
            solution = true_solution
        else
            # true_solutionがfalse,nilの場合
            # 正解した時点のs_score_tableの最も可能性の高いSolutionインスタンス（正解）をsolutionに代入
            solution = guess_solution(gen_solution_score_table(progress))
        end

        # 正解のsolutionのfeaturesをfに繰り返し代入し、キー：そのquestion_id、value：そのvalueとした連想配列をqid_feature_tableに代入
        qid_feature_table = {}
        solution.features.each do |f|
            qid_feature_table[f.question_id] = f.value
        end
        
        # progressのanswersを繰り返しansに代入し、
        progress.answers.each do |ans|
            if qid_feature_table.key?(ans.question_id)
                # もし、ansのquestion_idがqid_feature_tableに含まれていれば
                # （つまり、正解のsolutionのfeaturesを導いた質問の中に、これまでの回答が含まれている場合）
                feature = solution.features.find_by(question_id: ans.question_id)
                if feature.nil?
                    feature = Feature.create(question_id: ans.question.id, solution_id: solution.id)
                end
                # キーがans.question_idであるqid_featuer_tableのvalueをfeatureに代入
                # （つまり、正解のFeatureのvalueを回答のvalueに更新するために、
                # これまでの回答の中の一つの質問とQuestionのidが一致する、正解のsolutionのfeature.valueをfeatureに代入）
                feature.value = qid_feature_table[ans.question_id]
            else
                # それ以外の場合（つまり、正解のsolutionのfeaturesを導いた質問の中に、これまでの回答が含まれていない場合）
                # つまり、どこかのタイミングで新しくできた質問を今回答え、新しくできた質問に対応するfeature.valueが今回の正解の選択肢になかった場合
                feature = Feature.create(question_id: ans.question.id, solution_id: solution.id, value: ans.value)
                # Featureをcreateして
                # これまでの回答のQuestion.idを新しいFeature.question_idに代入
                # true_solution?又は、現在のs_score_tableの最も可能性の高いSolutionインスタンスのidを新しいFeature.solution_idに代入
                # これまでの回答のvalueをFeature.valueに代入
            end
            session[:feature] = feature
        end
    end

    def simple_text(text)
        reply_content = {
            type: 'text',
            text: text
        }
        return reply_content
    end

    def set_confirm_template(question_message)
        reply_content = {
            type: 'template',
            altText: "「はい」か「いいえ」で答えてね！",
            template: {
              type: 'confirm',
              text: "質問：" + question_message + "\n\n途中で終わる場合は「終了」と打って！",
              actions: [
                {
                  type: 'message',
                  label: "はい",
                  text: "はい"
                },
                {
                  type: 'message',
                  label: "いいえ",
                  text: "いいえ"
                }
              ]
            }
        }
        return reply_content
    end

    def set_butten_template(altText:, title:, text:)
        reply_content = {
            type: 'template',
            altText: altText,
            template: {
                type: 'buttons',
                text: title,
                actions: [
                    {
                    type: 'message',
                    label: text,
                    text: text
                    }
                ]
            }
        }
        return reply_content
    end

    def set_butten_uri_template(text: ,uri:)
        reply_content = {
            type: 'template',
            altText: "検索結果",
            template: {
                type: 'buttons',
                text: text,
                actions: [
                    {
                    type: 'uri',
                    label: "検索結果（グーグル検索）",
                    uri: "https://www.google.com/search?" + uri
                    }
                ]
            }
        }
        return reply_content
    end

    # GameStatusがPendingの場合akinator_handlerで呼び出されるメソッド、引数はUserStatus, message、返り値は配列[(text, items)]
    def handle_pending(user_status, message)
        if message == "はじめる"
            # Progressをcreateして、UserStatusのprogressに代入
            user_status.progress = Progress.create()
            all_solution = Solution.all
            # Solutionの行を全て取得し（選択肢を全て取得）、UserStatusのprogressのcandidatesに代入
            user_status.progress.solutions << all_solution
            # 上で定義したselect_next_questionメソッド（返り値はq_score_tableのfeature.valueが最小のQuestionインスタンス）を呼び出しquestionに代入
            question = select_next_question(user_status.progress)
            # 上で定義したsave_statusメソッドを呼び出す（引数は、UserStatusインスタンス, GameState, Questionインスタンス）
            save_status(user_status, new_status: 'asking', next_question: question)
            # set_confirm_templateでquestion.messageに対して「はい」「いいえ」の確認テンプレートを作成、返り値はreply_content={}
            reply_content = set_confirm_template(question.message)
        else
            # set_butten_templateでtitleのvalueをテキストに、textのvalueをボタンにする。
            reply_content = set_butten_template(altText: "今日何食べる？", title: "「はじめる」をタップ！\n（「はじめる」してから最初の質問まで15秒ほどかかります。。。）", text: "はじめる")
        end
        return reply_content  
    end

    # GameStatusがAskingの場合akinator_handlerで呼び出されるメソッド、引数はUserStatus, message、返り値はreply_content
    def handle_asking(user_status, message)
        if ["はい", "いいえ"].include?(message)
            # ["はい", "いいえ"]がmessageに含まれる場合
            # UserStatusのprogressとmessageを引数に、AnswerをProgress、セッションにpush
            push_answer(user_status.progress, message)
            # 現在のs_score_tableをold_s_score_tableに代入
            old_s_score_table = gen_solution_score_table(user_status.progress)
            # これで、ProgressのAnswerが変わり、現在のスコアを古いものとして代入したので、s_score_tableを変更する準備が整った
            # update_candidatesメソッドでSolution.valueの平均以上の選択肢を取得し、Progressのcandidatesが更新された
            user_status.progress.solutions = update_candidates(old_s_score_table)
            user_status.progress.solutions.each do |c|
                # 候補：id:, name:""でプリント
                p ("candidate=> id: #{c.id}, name: #{c.name}")
            end
            # Progressのcandidatesが更新された状態の現在のs_score_tableをs_score_tableに代入
            s_score_table = gen_solution_score_table(user_status.progress)
            if can_decide(s_score_table, old_s_score_table).blank?
                # s_score_tableとold_s_score_tableを比較したりして、選択肢が変わった場合（返り値がtrueで無い場合）
                question = select_next_question(user_status.progress)
                if question.nil? || question.id == user_status.progress.questions.last.id
                    # 現在のs_score_tanleを引数に、最もAnswersとFeatureが近いSolutionを取得して代入
                    most_likely_solution = guess_solution(s_score_table)
                    question_message = "あなたが今食べたいのは\n\n" + most_likely_solution.name + "\n\nかと思うけど、どうかな?"
                    # GameStateをGuessingにして、save_status
                    save_status(user_status, new_status: 'guessing')
                    # set_confirm_templateでquestion_messageに対して「はい」「いいえ」の確認テンプレートを作成、返り値はreply_content={}
                    reply_content = set_confirm_template(question_message)
                else
                    save_status(user_status, next_question: question)
                    # set_confirm_templateでquestion.messageに対して「はい」「いいえ」の確認テンプレートを作成、返り値はreply_content={}
                    reply_content = set_confirm_template(question.message)
                end

            else
                # 選択肢が変わらなかった場合（返り値がtrueの場合）
                # 現在のs_score_tanleを引数に、最もAnswersとFeatureが近いSolutionを取得して代入
                most_likely_solution = guess_solution(s_score_table)
                question_message = "あなたが今食べたいのは\n\n" + most_likely_solution.name + "\n\nかと思うけど、どうかな?"
                # GameStateをGuessingにして、save_status
                save_status(user_status, new_status: 'guessing')
                # ser_confirm_templateでquestion_messageに対して「はい」「いいえ」の確認テンプレートを作成、返り値はreply_content={}
                reply_content = set_confirm_template(question_message)
            end
        else
            # ["はい", "いいえ"]がmessageに含まれない場合
            question = select_next_question(user_status.progress)
            reply_content = set_confirm_template("「はい」か「いいえ」で答えてね！\n#{question.message}")
        end
        return reply_content
    end

    # handle_askingで選択肢が変わらなかった場合にGameStateがGuessingとなり呼び出されるメソッド
    # 引数はUserStatus, message、返り値はreply_content
    def handle_guessing(user_status, message)
        if message == "はい"
            # most_likely_solutionが当たった場合
            s_score_table = gen_solution_score_table(user_status.progress)
            most_likely_solution = guess_solution(s_score_table)
            reply_content = set_butten_uri_template(text:"じゃあ、食べたいものを現在地で検索するね！\n（LINEの設定により、正確な現在地ではない可能性があります。）", uri: URI.encode_www_form([["q", "#{most_likely_solution.name} 現在地"]]))
            # 正解の選択肢が見つかったので、その選択肢のFeature.valueを今回の回答に更新し、新しくQuestionとFeatureがあった場合は新規作成
            update_features(user_status.progress)
            # 今回のAnswerとUserStatusのprogressを全て削除
            reset_status(user_status)
        elsif message == "いいえ"
            # most_likely_solutionが当たった場合
            reply_content = set_confirm_template("ありゃ、ごめんなさい！続けて質問していいですか？")
            # UserStatusは変わらないが、GameStateをGUESSINGからRESUMINGに更新
            save_status(user_status, new_status: 'resuming')
        else
            # ["はい", "いいえ"]がmessageに含まれない場合
            reply_content = set_confirm_template("「はい」か「いいえ」で教えて下さい！\n続けて質問していいですか？")
        end
        return reply_content
    end

    # handle_guessingで最も可能性が高い選択肢が解答でなかった場合にGameStateがResumingになり呼び出されるメソッド
    # 引数はUserStatus, message、返り値は配列[(text, items)]
    def handle_resuming(user_status, message)
        if message == "はい"
            # 外したが、続ける場合
            question = select_next_question(user_status.progress)
            if question.nil?
                items = []
                user_status.progress.solutions.first(5).each do |s|
                    items.push(s.name)
                    # reply_content用にitemsを用意。中身はこれまでで絞り込んだcandidatesを順に5個まで
                end
                reply_content = simple_text("質問がなくなってしまいました…。\n以下が質問の結果に一番近いので、食べたいものがあれば打って教えて下さい！\n\n#{items.join("\n")}\n\nピンとくるものが無ければ、「ない」と打ってね。")
                # user_status.statusをbeggingに更新
                save_status(user_status, new_status: 'begging')
            else
                all_solution = Solution.all
                # UserStatusのProgressのcandidatesをSolutionのインスタンスを全てにする
                # つまり、これまでの回答で絞り込んだcandidatesを選択肢全てにする
                user_status.progress.solutions << all_solution
                reply_content = set_confirm_template(question.message)
                # GamestateをAskingにする。next_questionもある。
                save_status(user_status, new_status: 'asking', next_question: question)
            end

        elsif message == "いいえ"
            # 外して、続けない場合
            items = []
            user_status.progress.solutions.first(5).each do |s|
                # reply_content用にitemsを用意。中身はこれまでで絞り込んだcandidatesを順に5個まで
                items.push(s.name)
            end
            reply_content = simple_text("OK！\n以下が質問の結果に一番近いので、食べたいものがあれば打って教えて下さい！\n\n#{items.join("\n")}\n\nピンとくるものが無ければ、「ない」と打ってね。")
            # user_status.statusをbeggingに更新
            save_status(user_status, new_status: 'begging')
        else
            # ["はい", "いいえ"]がmessageに含まれない場合
            reply_content = set_confirm_template("「はい」か「いいえ」で教えて下さい！\n続けて質問していい？")
        end
        return reply_content
    end

    # handle_resumingで続けない場合、candidatesと、"どれも当てはまらない"を提示して、GameStateがBeggingになり呼び出されるメソッド
    # 引数はUserStatusとmessage、返り値は配列[(text, items)]
    def handle_begging(user_status, message)
        s_names = []
        Solution.all.each do |s|
            s_names.push(s.name)
        end

        if s_names.include?(message)
            # candidatesと"どれも当てはまらない"への返信がSolution全ての中の一つに当てはまるかを繰り返しチェックし、存在する場合
            # messsage(教えてもらったSolutionのname)とSolution.nameが一致する最初の一つを本当の解答として代入
            true_solution = Solution.find_by(name: message)
            # 教えてもらった本当の解答を引数に、本当の解答のFeature.valueを今回の回答に更新し、新しくQuestionとFeatureがあった場合は新規作成
            update_features(user_status.progress, true_solution: true_solution)
            # 今回のAnswerとUserStatusのprogressを全て削除
            reset_status(user_status)
            # GameStateをPendingに更新
            save_status(user_status, new_status: 'pending')
            reply_content = set_butten_uri_template(text:"教えてくれてありがとう！\nじゃあ、食べたいものを現在地で検索するね！\n（LINEの設定により、正確な現在地ではない可能性があります。）", uri: URI.encode_www_form([["q", "#{true_solution.name} 現在地"]]))
        else
            # 当てはまらなかった場合
            # user_status.statusをpendingに更新
            save_status(user_status, new_status: 'pending')
            # 今回のAnswerとUserStatusのprogressを全て削除
            # user_status.statusをregisteringに変更
            reset_status(user_status)
            reply_content = set_butten_template(
                altText: "また遊んでね！",
                title: "分かりませんでした…。次は当てます！\nまた遊ぶときは「はじめる」をタップ！",
                text: "はじめる"
            )
        end
        return reply_content
    end


    # handle_beggingでSolutionsに該当のものがない場合、新規にSolutionを作成するメソッド
    # 引数はUserStatusとmessage、返り値は配列[(text, items)]
    def handle_registering(user_status, message)
        # preparedSolutionをcreateして代入
        # カラムはid, progress_id, name
        prepared_solution = PreparedSolution.create()
        # message（教えてもらった答え）をnameとして代入
        prepared_solution.name = message
        # UserStatesのProgressのprepared_solutionに代入
        user_status.progress.prepared_solution = prepared_solution
        # user_status.statusをconfirmingに更新
        save_status(user_status, new_status: 'confirming')
        reply_content = set_confirm_template("思い浮かべていたのは\n\n#{message}\n\nでいいですか？")
        return reply_content
    end

    # handle_registeringで教えてもらった答えをprepared_solutionとして代入して、提示して、GameStateがConfirmingになり呼び出されるメソッド
    def handle_confirming(user_status, message)
        # 教えてもらった答えをpre_solutionに代入
        pre_solution = user_status.progress.prepared_solution
        # 教えてもらった答えのnameをnameに代入しておく
        name = pre_solution.name
        if message == "はい"
            # handle_registeringで提示したset_confirm_templateの「はい」を押下した場合
            # Solutionをcreateして教えてもらった答えのnameを代入
            new_solution = Solution.create(name: name)
            # pre_solutionをテーブルから削除
            pre_solution.destroy
            # new_solutionのFeature.valueを更新して、新しくQuestionとFeatureがあった場合は新規作成
            update_features(user_status.progress, true_solution: new_solution)
            reply_content = set_butten_template(
                altText: "覚えました！",
                title: "#{name}ですね、覚えておきます。ありがとうございました！\nまた遊ぶときは「はじめる」をタップ！",
                text: "はじめる")

            # user_status.statusをpendingに更新
            save_status(user_status, new_status: 'pending')
            # 今回のAnswerとUserStatusのprogressを全て削除
            reset_status(user_status)
        elsif message == "いいえ"
            # handle_registeringで提示したQuickMessageFormに対して"いいえ"の場合
            # pre_solutionをテーブルから削除
            pre_solution.destroy
            # user_status.statusをregisteringに更新
            save_status(user_status, new_status: 'registering')
            reply_content = simple_text("ありゃ、もう一度食べたいものを教えて下さい")
        else
            # それ以外のmessageが来た場合
            # GameStateは更新せず、同じことを繰り返す
            reply_content = set_confirm_template("思い浮かべていたのは\n\n#{message}\n\nでいいですか？")
        end
        return reply_content
    end

    private
        def client
            @client ||= Line::Bot::Client.new { |config|
                config.channel_secret = ENV["LINE_CHANNEL_SECRET"]
                config.channel_token = ENV["LINE_CHANNEL_TOKEN"]
              }
        end
end