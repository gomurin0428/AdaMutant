with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with AdaMutant.Config;
with AdaMutant.Mutators;
with AdaMutant.Positions;

package body AdaMutant.Reports is

   use AdaMutant.Results;

   Hex : constant String := "0123456789abcdef";

   function Image (N : Integer) return String is
     (Ada.Strings.Fixed.Trim (N'Image, Ada.Strings.Both));

   function One_Line (S : String) return String is
      function Blank (C : Character) return Boolean is
        (C = ' ' or else C = ASCII.HT);
      function Break (C : Character) return Boolean is
        (C = ASCII.LF or else C = ASCII.CR);
      Result : Unbounded_String;
      K      : Natural := S'First;
   begin
      while K <= S'Last loop
         if Break (S (K)) then
            while Length (Result) > 0
              and then Blank (Element (Result, Length (Result)))
            loop
               Delete (Result, Length (Result), Length (Result));
            end loop;
            while K <= S'Last and then (Blank (S (K)) or else Break (S (K)))
            loop
               K := K + 1;
            end loop;
            Append (Result, ' ');
         else
            Append (Result, S (K));
            K := K + 1;
         end if;
      end loop;
      return To_String (Result);
   end One_Line;

   function Json_String (S : String) return String is
      R : Unbounded_String := To_Unbounded_String ("""");
      K : Natural := S'First;

      function Seq_Length (B : Natural) return Natural is
        (if B < 16#80# then 1
         elsif B in 16#C2# .. 16#DF# then 2
         elsif B in 16#E0# .. 16#EF# then 3
         elsif B in 16#F0# .. 16#F4# then 4
         else 0);

      procedure Escape (B : Natural) is
      begin
         Append (R, "\u00" & Hex (B / 16 + 1) & Hex (B mod 16 + 1));
      end Escape;
   begin
      while K <= S'Last loop
         declare
            C : constant Character := S (K);
            B : constant Natural := Character'Pos (C);
            L : constant Natural := Seq_Length (B);
         begin
            if C = '"' then
               Append (R, "\""");
            elsif C = '\' then
               Append (R, "\\");
            elsif C = ASCII.LF then
               Append (R, "\n");
            elsif C = ASCII.CR then
               Append (R, "\r");
            elsif C = ASCII.HT then
               Append (R, "\t");
            elsif C = '<' then
               --  Keeps the JSON safe inside an HTML script element.
               Append (R, "\u003c");
            elsif B < 16#20# or else B = 16#7F# then
               Escape (B);
            elsif L = 1 then
               Append (R, C);
            elsif L > 1 and then K + L - 1 <= S'Last
              and then (for all J in K + 1 .. K + L - 1 =>
                          Character'Pos (S (J)) / 64 = 2)
              and then not (B = 16#E0# and then Character'Pos (S (K + 1)) < 16#A0#)
              and then not (B = 16#ED# and then Character'Pos (S (K + 1)) > 16#9F#)
              and then not (B = 16#F0# and then Character'Pos (S (K + 1)) < 16#90#)
              and then not (B = 16#F4# and then Character'Pos (S (K + 1)) > 16#8F#)
            then
               Append (R, S (K .. K + L - 1));
               K := K + L - 1;
            else
               Escape (B);
            end if;
         end;
         K := K + 1;
      end loop;
      Append (R, """");
      return To_String (R);
   end Json_String;

   function Json (R : Report) return String is
      Out_Text : Unbounded_String;
      S        : AdaMutant.Config.Configuration renames R.Settings;

      procedure Add (T : String) is
      begin
         Append (Out_Text, T);
      end Add;

      function Names (List : AdaMutant.Config.String_Vector) return String is
         Result : Unbounded_String := To_Unbounded_String ("[");
      begin
         for K in List.First_Index .. List.Last_Index loop
            Append (Result, (if K > List.First_Index then "," else "")
                    & Json_String (List (K)));
         end loop;
         return To_String (Result) & "]";
      end Names;

      function Pos (P : AdaMutant.Positions.Position) return String is
        ("{""line"":" & Image (P.Line) & ",""column"":" & Image (P.Column)
         & "}");
   begin
      Add ("{""schemaVersion"":""2"",""thresholds"":{""high"":"
           & Image (Integer (S.High)) & ",""low"":" & Image (Integer (S.Low))
           & "},""projectRoot"":" & Json_String (To_String (S.Root))
           & ",""framework"":{""name"":""AdaMutant"",""version"":"
           & Json_String (AdaMutant.Version) & "}");
      if S.Named_Tests then
         --  The tests are the entries of the [tests] table of the
         --  configuration.
         Add (",""testFiles"":{""adamutant.toml"":{""tests"":[");
         for T in S.Tests.First_Index .. S.Tests.Last_Index loop
            Add ((if T > S.Tests.First_Index then "," else "")
                 & "{""id"":" & Json_String (To_String (S.Tests (T).Name))
                 & ",""name"":" & Json_String (To_String (S.Tests (T).Name))
                 & "}");
         end loop;
         Add ("]}}");
      end if;
      Add (",""files"":{");
      for F in R.Files.First_Index .. R.Files.Last_Index loop
         if F > R.Files.First_Index then
            Add (",");
         end if;
         Add (Json_String (To_String (R.Files (F).Path))
              & ":{""language"":""ada"",""source"":"
              & Json_String (To_String (R.Files (F).Source))
              & ",""mutants"":[");
         declare
            First : Boolean := True;
         begin
            for M of R.Mutants loop
               if M.File = F then
                  if not First then
                     Add (",");
                  end if;
                  First := False;
                  Add ("{""id"":" & Json_String (Image (M.Id))
                       & ",""mutatorName"":"
                       & Json_String (AdaMutant.Mutators.Name (M.Mutation.Kind))
                       & ",""replacement"":"
                       & Json_String (To_String (M.Mutation.Replacement))
                       & ",""location"":{""start"":" & Pos (M.Start_Pos)
                       & ",""end"":" & Pos (M.End_Pos) & "}"
                       & ",""status"":" & Json_String (Name (M.Status)));
                  if Length (M.Status_Reason) > 0 then
                     Add (",""statusReason"":"
                          & Json_String (To_String (M.Status_Reason)));
                  end if;
                  if M.Reached = Covered then
                     Add (",""coveredBy"":" & Names (M.Covered_By));
                  elsif M.Reached = Not_Covered then
                     Add (",""coveredBy"":[]");
                  end if;
                  if M.Killed_By = Proof and then not M.Failed_Checks.Is_Empty
                  then
                     Add (",""killedBy"":[");
                     for K in M.Failed_Checks.First_Index
                       .. M.Failed_Checks.Last_Index
                     loop
                        Add ((if K > M.Failed_Checks.First_Index then ","
                              else "")
                             & Json_String ("proof: " & M.Failed_Checks (K)));
                     end loop;
                     Add ("]");
                  elsif M.Killed_By = Tests and then not M.Killers.Is_Empty
                  then
                     Add (",""killedBy"":" & Names (M.Killers));
                  elsif M.Killed_By /= None then
                     Add (",""killedBy"":["
                          & Json_String (if M.Killed_By = Tests then "tests"
                                         else "proof") & "]");
                  end if;
                  if M.Tests_Run > 0 then
                     Add (",""testsCompleted"":" & Image (M.Tests_Run));
                  end if;
                  Add (",""duration"":"
                       & Image (Integer (M.Elapsed * 1000.0)) & "}");
               end if;
            end loop;
         end;
         Add ("]}");
      end loop;
      Add ("}}");
      return To_String (Out_Text);
   end Json;

   Page_Head : constant String :=
     "<!DOCTYPE html><html lang=""en""><head><meta charset=""utf-8"">"
     & "<title>AdaMutant report</title><style>"
     & "body{font-family:system-ui,sans-serif;margin:2em;color:#222}"
     & "table{border-collapse:collapse}td,th{border:1px solid #ccc;"
     & "padding:4px 8px;text-align:right}td:first-child,th:first-child"
     & "{text-align:left}.high{background:#c8f0c8}.mid{background:#f8eeb0}"
     & ".low{background:#f6c4c4}pre{background:#f7f7f7;padding:8px;"
     & "overflow:auto;line-height:1.4}.mut{cursor:pointer;border-radius:3px}"
     & ".Killed,.Timeout{background:#c8f0c8}.Survived,.NoCoverage"
     & "{background:#f6c4c4}.CompileError,.RuntimeError,.Ignored"
     & "{background:#e0e0e0}.detail{margin:4px 0 4px 2em;font-size:90%}"
     & "a{color:#0645ad}</style></head><body><h1>AdaMutant report</h1>"
     & "<div id=""app""></div><script id=""data"" type=""application/json"">";

   Page_Tail : constant String :=
     "</script><script>"
     & "const r=JSON.parse(document.getElementById('data').textContent);"
     & "const app=document.getElementById('app');"
     & "const esc=s=>s.replace(/[&<>""]/g,c=>({'&':'&amp;','<':'&lt;',"
     & "'>':'&gt;','""':'&quot;'}[c]));"
     & "const det=['Killed','Timeout'],und=['Survived','NoCoverage'];"
     & "function score(ms){let d=ms.filter(m=>det.includes(m.status)).length,"
     & "u=ms.filter(m=>und.includes(m.status)).length;"
     & "return d+u?100*d/(d+u):NaN}"
     & "function cls(s){return isNaN(s)?'':s>=r.thresholds.high?'high':"
     & "s>=r.thresholds.low?'mid':'low'}"
     & "const st=['Killed','Survived','Timeout','NoCoverage','CompileError',"
     & "'RuntimeError','Ignored'];"
     & "let all=[];for(const f in r.files)all=all.concat(r.files[f].mutants);"
     & "let h='<table><tr><th>File</th><th>Score</th>'+st.map(s=>'<th>'+s+"
     & "'</th>').join('')+'</tr>';"
     & "function row(n,ms,link){const s=score(ms);return '<tr><td>'+(link?"
     & "'<a href=""#'+encodeURIComponent(n)+'"">'+esc(n)+'</a>':esc(n))+"
     & "'</td><td class=""'+cls(s)+'"">'+(isNaN(s)?'n/a':s.toFixed(2))+"
     & "'</td>'+st.map(x=>'<td>'+ms.filter(m=>m.status==x).length+'</td>')"
     & ".join('')+'</tr>'}"
     & "h+=row('All files',all,false);"
     & "for(const f in r.files)h+=row(f,r.files[f].mutants,true);h+='</table>';"
     & "for(const f in r.files){const src=r.files[f].source,"
     & "lines=src.split('\n'),ms=r.files[f].mutants;"
     & "h+='<h2 id=""'+encodeURIComponent(f)+'"">'+esc(f)+'</h2><pre>';"
     & "const by={};for(const m of ms)(by[m.location.start.line]=by"
     & "[m.location.start.line]||[]).push(m);"
     & "lines.forEach((l,i)=>{const n=i+1,lm=by[n]||[];"
     & "const worst=lm.find(m=>und.includes(m.status))||lm.find(m=>"
     & "det.includes(m.status))||lm[0];"
     & "h+='<span'+(worst?' class=""mut '+worst.status+'"" onclick=""t('+n+"
     & "',\''+encodeURIComponent(f)+'\')""':'')+'>'+String(n).padStart(5)+"
     & "' '+esc(l)+'</span>\n';"
     & "if(lm.length)h+='<div class=""detail"" id=""d'+n+'_'+encodeURIComponent"
     & "(f)+'"" hidden>'+lm.map(m=>'<div><span class=""'+m.status+'"">'+"
     & "m.status+'</span> #'+m.id+' '+m.mutatorName+': <code>'+esc(lines[n-1]"
     & ".slice(m.location.start.column-1,m.location.start.line==m.location.end"
     & ".line?m.location.end.column-1:undefined))+'</code> &rarr; <code>'+"
     & "esc(m.replacement)+'</code>'+(m.statusReason?' ('+esc(m.statusReason)"
     & "+')':'')+'</div>').join('')+'</div>'});h+='</pre>'}"
     & "app.innerHTML=h;"
     & "function t(n,f){const e=document.getElementById('d'+n+'_'+f);"
     & "if(e)e.hidden=!e.hidden}"
     & "</script></body></html>";

   function Html (R : Report) return String is
     (Page_Head & Json (R) & Page_Tail);

   procedure Print_Console (R : Report) is
      All_Counts : constant Status_Counts := AdaMutant.Results.Count (R);

      function Pad (S : String; W : Natural; Right : Boolean := True)
        return String is
        (if S'Length >= W then S
         elsif Right then [1 .. W - S'Length => ' '] & S
         else S & [1 .. W - S'Length => ' ']);

      Name_Width : Natural := 9;

      procedure Row (Label : String; C : Status_Counts) is
      begin
         Ada.Text_IO.Put_Line (Pad (Label, Name_Width, False) & " |"
                   & Pad (Score_Image (C), 8) & " |"
                   & Pad (Image (C (Killed)), 7) & " |"
                   & Pad (Image (C (Timeout)), 8) & " |"
                   & Pad (Image (C (Survived)), 9) & " |"
                   & Pad (Image (C (No_Coverage)), 7) & " |"
                   & Pad (Image (C (Compile_Error)), 8) & " |"
                   & Pad (Image (C (Ignored)), 8));
      end Row;

      procedure Put_Mutant (M : Mutant; Note : String) is
         --  Where M is, a note in parentheses if any, and the change.
      begin
         Ada.Text_IO.Put_Line ("  #" & Image (M.Id) & " "
                   & To_String (R.Files (M.File).Path) & ":"
                   & Image (M.Start_Pos.Line) & ":"
                   & Image (M.Start_Pos.Column) & " "
                   & AdaMutant.Mutators.Name (M.Mutation.Kind)
                   & (if Note = "" then "" else " (" & Note & ")"));
         Ada.Text_IO.Put_Line
           ("    - " & One_Line (To_String (M.Original)));
         Ada.Text_IO.Put_Line
           ("    + " & One_Line (To_String (M.Mutation.Replacement)));
      end Put_Mutant;

      function Checks (M : Mutant) return String is
         S : Unbounded_String;
      begin
         for Kind of M.Failed_Checks loop
            Append (S, (if Length (S) > 0 then ", " else "") & Kind);
         end loop;
         return To_String (S);
      end Checks;
   begin
      for F of R.Files loop
         Name_Width := Natural'Max (Name_Width, Length (F.Path));
      end loop;

      --  The tests run first, so the proof only sees what they miss.
      if (for some M of R.Mutants =>
            M.Status = Killed and then M.Killed_By = Proof)
      then
         Ada.Text_IO.New_Line;
         Ada.Text_IO.Put_Line
           ("Detected only by the proof (candidates for a missing test):");
         for M of R.Mutants loop
            if M.Status = Killed and then M.Killed_By = Proof then
               Put_Mutant
                 (M, Checks (M)
                     & (if M.Reached /= Not_Covered then ""
                        elsif M.Failed_Checks.Is_Empty
                        then "no test executes this code"
                        else "; no test executes this code"));
            end if;
         end loop;
      end if;

      if All_Counts (Survived) > 0 then
         Ada.Text_IO.New_Line;
         Ada.Text_IO.Put_Line ("Survived mutants:");
         for M of R.Mutants loop
            if M.Status = Survived then
               Put_Mutant
                 (M, (if Proof_Timed_Out (M) then "the proof timed out"
                      else ""));
            end if;
         end loop;
      end if;

      if (for some M of R.Mutants => M.Equivalent) then
         Ada.Text_IO.New_Line;
         Ada.Text_IO.Put_Line
           ("Equivalent mutants (same object code as the unmodified"
            & " project, ignored):");
         for M of R.Mutants loop
            if M.Equivalent then
               Put_Mutant (M, "");
            end if;
         end loop;
      end if;

      --  The lines that no test executes, once each: there the mutation
      --  does not matter to the tests, and their mutants go to the proof.
      declare
         Header : Boolean := False;
         K      : Positive := R.Mutants.First_Index;
         Last   : Positive;
      begin
         while K <= R.Mutants.Last_Index loop
            Last := K;
            if R.Mutants (K).Reached = Not_Covered then
               while Last < R.Mutants.Last_Index
                 and then R.Mutants (Last + 1).Reached = Not_Covered
                 and then R.Mutants (Last + 1).File = R.Mutants (K).File
                 and then R.Mutants (Last + 1).Start_Pos.Line
                          = R.Mutants (K).Start_Pos.Line
               loop
                  Last := Last + 1;
               end loop;
               if not Header then
                  Ada.Text_IO.New_Line;
                  Ada.Text_IO.Put_Line ("Lines that no test executes:");
                  Header := True;
               end if;
               Ada.Text_IO.Put_Line
                 ("  " & To_String (R.Files (R.Mutants (K).File).Path) & ":"
                  & Image (R.Mutants (K).Start_Pos.Line) & " ("
                  & Image (Last - K + 1)
                  & (if Last = K then " mutant)" else " mutants)"));
            end if;
            K := Last + 1;
         end loop;
      end;

      --  What each test of the [tests] table does.
      if R.Settings.Named_Tests then
         declare
            S      : AdaMutant.Config.Configuration renames R.Settings;
            Width  : Natural := 4;
            Idle   : Unbounded_String;
            --  Without coverage analysis it is not known what a test
            --  executes.
            Known  : constant Boolean :=
              (for some M of R.Mutants => M.Reached /= Unknown);
         begin
            for T of S.Tests loop
               Width := Natural'Max (Width, Length (T.Name));
            end loop;
            Ada.Text_IO.New_Line;
            Ada.Text_IO.Put_Line
              (Pad ("Test", Width, False) & " | Covers | Kills");
            Ada.Text_IO.Put_Line ([1 .. Width + 17 => '-']);
            for T of S.Tests loop
               declare
                  Name          : constant String := To_String (T.Name);
                  Covers, Kills : Natural := 0;
               begin
                  for M of R.Mutants loop
                     if M.Covered_By.Contains (Name) then
                        Covers := Covers + 1;
                     end if;
                     if M.Killers.Contains (Name) then
                        Kills := Kills + 1;
                     end if;
                  end loop;
                  Ada.Text_IO.Put_Line
                    (Pad (Name, Width, False) & " |"
                     & Pad ((if Known then Image (Covers) else "-"), 7) & " |"
                     & Pad (Image (Kills), 6));
                  if Kills = 0 then
                     Append (Idle, (if Length (Idle) > 0 then ", " else "")
                             & Name);
                  end if;
               end;
            end loop;
            if S.Bail then
               Ada.Text_IO.Put_Line
                 ("A mutant counts for the first test that detects it;"
                  & " bail = false counts every test.");
            elsif Length (Idle) > 0 then
               Ada.Text_IO.Put_Line
                 ("Tests that detect no mutant: " & To_String (Idle));
            end if;
         end;
      end if;

      --  What the proof detects the mutants with.
      declare
         Kinds  : AdaMutant.Config.String_Vector;
         Width  : Natural := 0;
      begin
         for M of R.Mutants loop
            for Kind of M.Failed_Checks loop
               if not Kinds.Contains (Kind) then
                  Kinds.Append (Kind);
                  Width := Natural'Max (Width, Kind'Length);
               end if;
            end loop;
         end loop;
         if not Kinds.Is_Empty then
            Ada.Text_IO.New_Line;
            Ada.Text_IO.Put_Line
              ("Mutants killed by the proof, by the check that fails"
               & " (alone: no other kind of check fails for the mutant):");
            for Kind of Kinds loop
               declare
                  Count, Alone : Natural := 0;
               begin
                  for M of R.Mutants loop
                     if M.Failed_Checks.Contains (Kind) then
                        Count := Count + 1;
                        if Natural (M.Failed_Checks.Length) = 1 then
                           Alone := Alone + 1;
                        end if;
                     end if;
                  end loop;
                  Ada.Text_IO.Put_Line
                    ("  " & Pad (Kind, Width, False) & " |"
                     & Pad (Image (Count), 6) & " |"
                     & Pad (Image (Alone), 6) & " alone");
               end;
            end loop;
         end if;
      end;

      Ada.Text_IO.New_Line;
      Ada.Text_IO.Put_Line (Pad ("File", Name_Width, False)
                & " | Score % | Killed | Timeout | Survived | No cov |"
                & " Compile | Ignored");
      Ada.Text_IO.Put_Line ([1 .. Name_Width + 69 => '-']);
      Row ("All files", All_Counts);
      for F in R.Files.First_Index .. R.Files.Last_Index loop
         Row (To_String (R.Files (F).Path), AdaMutant.Results.Count (R, F));
      end loop;
   end Print_Console;

end AdaMutant.Reports;
