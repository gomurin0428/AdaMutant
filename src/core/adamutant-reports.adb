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

      function Pos (P : AdaMutant.Positions.Position) return String is
        ("{""line"":" & Image (P.Line) & ",""column"":" & Image (P.Column)
         & "}");
   begin
      Add ("{""schemaVersion"":""2"",""thresholds"":{""high"":"
           & Image (Integer (S.High)) & ",""low"":" & Image (Integer (S.Low))
           & "},""projectRoot"":" & Json_String (To_String (S.Root))
           & ",""framework"":{""name"":""AdaMutant"",""version"":"
           & Json_String (AdaMutant.Version) & "},""files"":{");
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
                  if M.Killed_By /= None then
                     Add (",""killedBy"":["
                          & Json_String (if M.Killed_By = Tests then "tests"
                                         else "proof") & "]");
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
   begin
      for F of R.Files loop
         Name_Width := Natural'Max (Name_Width, Length (F.Path));
      end loop;

      if All_Counts (Survived) > 0 then
         Ada.Text_IO.New_Line;
         Ada.Text_IO.Put_Line ("Survived mutants:");
         for M of R.Mutants loop
            if M.Status = Survived then
               Ada.Text_IO.Put_Line ("  #" & Image (M.Id) & " "
                         & To_String (R.Files (M.File).Path) & ":"
                         & Image (M.Start_Pos.Line) & ":"
                         & Image (M.Start_Pos.Column) & " "
                         & AdaMutant.Mutators.Name (M.Mutation.Kind));
               Ada.Text_IO.Put_Line
                 ("    - " & One_Line (To_String (M.Original)));
               Ada.Text_IO.Put_Line
                 ("    + " & One_Line (To_String (M.Mutation.Replacement)));
            end if;
         end loop;
      end if;

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
