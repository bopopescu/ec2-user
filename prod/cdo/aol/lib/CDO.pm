package CDO;

use dbiConfig;
use Math::Round qw( :all );
use DateFunctions;
use CDO_Q_Calc;
use apiConfig;
use cdoPopulate;
use Logger;
use Notify;
use bidOps;

my $dbi = dbiConfig->dbiConnect('');

my $DateFunctions = new DateFunctions;
my $Q_Calc = new CDO_Q_Calc;
my $logger = new Logger;
my $notify = new Notify;

####GLOBAL VARIABLES
my $max_alpha_default = 0.2;
my $min_bid = apiConfig->getCommonParam('minBid');
my $budget_default = apiConfig->getCommonParam('defaultBudget');
my $cost_method = 2; # 1 = OLD, 2 = NEW
my $includes = "'auoapi1amdec10','aigebi1amjul11','bmcebi1amjul11'";

sub new
{
    my $self = {};
    bless $self;
    return $self;
}

sub Params {
	my($self, $log) = @_;

$logger->write($log, $DateFunctions->currentTime().": Loading Campaign Budgets\n");
 ### Campaign Config
     my $sql = qq| SELECT san, totalbudget
                   FROM Campaign
                   WHERE usepoe=1
                   AND isapi=1
                   |;

    my $sth = $dbi->prepare($sql);
    $sth->execute();
    my $campConfig = $sth->fetchall_hashref(san);
    
    foreach my $san (sort keys %{$campConfig})
    	{
    		$logger->write($log, "           -> $san has a daily budget of $$campConfig{$san}{'totalbudget'}.\n");
   		}

##Max Alphas
#Cell-Specific Max Alpha
$logger->write($log, $DateFunctions->currentTime().": Loading Cell Level Max Allocations\n");
	
#        my $sql = qq| SELECT cell.san+'_'+cast(cell.adid as varchar)+'_'+cast(cell.siteid as varchar)+'_'+cast(cell.segmentid as varchar)+'_'+cast(cell.size as varchar) as id,
#							cell.san, cell.adid, cell.siteid, cell.segmentid, cell.size, cell.allocation
#					FROM CellAllocation cell, Campaign c, Media m
#					WHERE cell.san=c.san
#						AND cell.adid=m.adid
#						AND c.usepoe=1
#						AND m.active=1 |;

        my $sql = qq| SELECT concat(cell.san,"_",cell.adid,"_",cell.siteid,"_",cell.segmentid,"_",cell.size) as id,
							cell.san, cell.adid, cell.siteid, cell.segmentid, cell.size, cell.allocation
					FROM CellAllocation cell, Campaign c, Media m
					WHERE cell.san=c.san
						AND cell.adid=m.adid
						AND c.usepoe=1
						AND m.active=1 |;
				
    my $sth = $dbi->prepare($sql);
    $sth->execute();
    my $cellMaxAlpha = $sth->fetchall_hashref(id);
    $sth->finish();
    
    if (keys %{$cellMaxAlpha} == 0) 
    	{
    		$logger->write($log, "********No Cell Level Allocation Caps.\n");
		}
	else 
		{
			$logger->write($log, "           -> ".keys(%{$cellMaxAlpha})." cell level allocation caps (see logs).\n");
		}
	

#Campaign-Level Max Alpha
$logger->write($log, $DateFunctions->currentTime().": Loading Campaign Level Max Allocations\n");
	my $sql = qq| SELECT camp.san, camp.allocation
					FROM CampaignAllocation camp, Campaign c
					WHERE camp.san=c.san
						AND c.usepoe=1
				|;
				
    my $sth = $dbi->prepare($sql);
    $sth->execute();
    my $campaignMaxAlpha = $sth->fetchall_hashref(san);
    
    if (keys %{$campaignMaxAlpha} == 0) 
    	{ 
    		$logger->write($log, "********No Campaign Level Allocation Caps.\n");
		}
	else
		{
			foreach my $key (sort keys %{$campaignMaxAlpha})
				{
					$logger->write($log, "           -> $key has a max allocation of $$campaignMaxAlpha{$key}{'allocation'}\n");
				}
		}

#Campaign Level Price Volume Availability
$logger->write($log, $DateFunctions->currentTime().": Getting Campaign PV Availability\n");
	my $sql = qq| SELECT DISTINCT san
                      FROM EVolumeTest |;
				
    my $sth = $dbi->prepare($sql);
    $sth->execute();
    my $campaignPV = $sth->fetchall_hashref(san);

        if (keys %{$campaignPV} == 0) 
    	{ 
            $logger->write($log, "********No Campaign Level PV Data Available.\n");
        }
	else
        {
            foreach my $key (sort keys %{$campaignPV})
            {
                $logger->write($log, "           -> $key\n");
            }
        }
		
	return($campConfig, $cellMaxAlpha, $campaignMaxAlpha, $campaignPV);
}

### MD Factors
sub getMDFactors {
    my ($self, $DIR, $log) = @_;
    my $ac = new apiConfig;

	$logger->write($log, $DateFunctions->currentTime().": Loading Misdelivery Factors\n");
	
	my $phase = $ac->getCommonParam('mdPhase');
	my $mdDate = $DateFunctions->getApiCurrentDate($phase);

#    my $sql = qq|
#    		SELECT m.san+'_'+cast(md.siteid as varchar)+'_'+cast(md.segmentid as varchar)+'_'+m.size as ind,
#    		m.san,md.siteid,md.segmentid,m.size,sum(eimpressions) as eimpressions,sum(impressions) as impressions
#    			FROM DisplayMisdelivery md, Media m
#    			WHERE md.adid=m.adid
#    			AND md.date >= '$mdDate'
#    		GROUP BY
#    			m.san+'_'+cast(md.siteid as varchar)+'_'+cast(md.segmentid as varchar)+'_'+m.size,
#    			m.san,md.siteid,md.segmentid,m.size |;

    my $sql = qq|
    		SELECT concat(m.san,"_",md.siteid,"_",md.segmentid,"_",m.size) as ind,
    		m.san,md.siteid,md.segmentid,m.size,sum(eimpressions) as eimpressions,sum(impressions) as impressions
    			FROM DisplayMisdelivery md, Media m
    			WHERE md.adid=m.adid
    			AND md.date >= '$mdDate'
    		GROUP BY
    			concat(m.san,"_",md.siteid,"_",md.segmentid,"_",m.size),
    			m.san,md.siteid,md.segmentid,m.size |;



    my $sth = $dbi->prepare($sql);
    $sth->execute();
    my $cellMdFactors = $sth->fetchall_hashref(ind);
    $logger->write($log, "           -> ".keys(%{$cellMdFactors})." campaign level misdelivery factors.\n");
    $sth->finish();
    
#    my $sql = qq|
#    		SELECT cast(md.siteid as varchar)+'_'+cast(md.segmentid as varchar)+'_'+m.size as ind,md.siteid,md.segmentid,m.size,sum(eimpressions) as eimpressions,sum(impressions) as impressions#
#				FROM DisplayMisdelivery md, Media m
#     			WHERE md.adid=m.adid
#          			 AND md.date >= '$mdDate'
#     			GROUP BY
#        			cast(md.siteid as varchar)+'_'+cast(md.segmentid as varchar)+'_'+m.size,md.siteid,md.segmentid,m.size |;

    my $sql = qq|
    		SELECT concat(md.siteid,"_",md.segmentid,"_",m.size) as ind, md.siteid,md.segmentid,m.size,sum(eimpressions) as eimpressions,sum(impressions) as impressions
				FROM DisplayMisdelivery md, Media m
     			WHERE md.adid=m.adid
          			 AND md.date >= '$mdDate'
     			GROUP BY
        			concat(md.siteid,"_",md.segmentid,"_",m.size),md.siteid,md.segmentid,m.size |;
    
    my $sth = $dbi->prepare($sql);
    $sth->execute();
    my $siteSegMdFactors = $sth->fetchall_hashref(ind);
    $logger->write($log, "           -> ".keys(%{$siteSegMdFactors})." site-segment level misdelivery factors.\n");
    $sth->finish();

		open(CMD, ">$DIR/cellMDRatios.csv");
		print CMD "SAN,Placement,eimps,imps,mdRatio\n";
		
		    foreach $ind (sort keys %{$cellMdFactors}) {
		             $$cellMdFactors{$ind}{'ratio'} = sprintf("%.6f", $$cellMdFactors{$ind}{'impressions'}/&noNull($$cellMdFactors{$ind}{'eimpressions'},1));
		             print CMD "$$cellMdFactors{$ind}{'san'},$ind,$$cellMdFactors{$ind}{'eimpressions'},$$cellMdFactors{$ind}{'impressions'},$$cellMdFactors{$ind}{'ratio'}\n";
		    }
		close CMD;
		
		open(SSMD, ">$DIR/siteSegMDRatios.csv");
		print SSMD "placement,eimps,imps,mdRatio\n";
		
		    foreach $ind (sort keys %{$siteSegMdFactors}) {
		             $$siteSegMdFactors{$ind}{'ratio'} = sprintf("%.6f", $$siteSegMdFactors{$ind}{'impressions'}/&noNull($$siteSegMdFactors{$ind}{'eimpressions'},1));
		             print SSMD "$ind,$$siteSegMdFactors{$ind}{'eimpressions'},$$siteSegMdFactors{$ind}{'impressions'},$$siteSegMdFactors{$ind}{'ratio'}\n";
		    }
		close SSMD;
    
    return ($cellMdFactors, $siteSegMdFactors);
}

### Imp/Budget Curves
sub GetSignals {
	my ($self, $dow, $log) = @_;
	
	$logger->write($log, $DateFunctions->currentTime().": Loading Impression and Budget Curves\n");
	
	my $ac = new apiConfig;
	my $cp = new cdoPopulate;
	my $phase = $ac->getCommonParam('signalPhase');
	
	my ($siteSegSignal, $networkSignal) = $cp->getImpSignals($dow, $phase);
		$logger->write($log, "           -> ".keys(%{$siteSegSignal})." Site Segment Level Signal Coefficients\n");
		$logger->write($log, "           -> ".keys(%{$networkSignal})." Network Level Signal Coefficients\n");
	my ($campaignBudgetSignal, $networkBudgetSignal) = $cp->getBudgetSignal($dow, $phase);
		$logger->write($log, "           -> ".keys(%{$campaignBudgetSignal})."  Campaign Budget Signal Coefficients\n");
		$logger->write($log, "           -> ".keys(%{$networkBudgetSignal})."  Network Budget Signal Coefficients\n");
		
	return($siteSegSignal, $networkSignal, $campaignBudgetSignal, $networkBudgetSignal);
}

sub GetCellData {
    my ($self, $DIR, $dow, $hour, $siteSegSignal, $networkSignal, $cellMdFactors, $siteSegMdFactors, $log) = @_;
    
    $logger->write($log, $DateFunctions->currentTime().": Loading performance data\n");
    
#    my $sql = qq|
#            SELECT *
#            FROM dbo.cdoDataAol cdo, Campaign c
#            WHERE
#                    cdo.san=c.san
#                    AND c.usepoe=1
#                    AND dow = $dow AND hour = $hour
#                    AND avail_impressions > 0
#                    AND avail_capped_impressions > 0
#	   
#         		|;

    my $sql = qq| SELECT cdo.cellid, cdo.adid, cdo.siteid, cdo.segmentid, m.size, m.san, m.adgroup
                  FROM cdoCells cdo, Media m, Campaign c
                  WHERE 
                   cdo.adid=m.adid
                   AND m.san=c.san
                   AND cdo.active=1
                   AND c.usepoe=1
                   AND m.active=1
                 |;

    my $sth = $dbi->prepare($sql);
    $sth->execute();
    my $Cell = $sth->fetchall_hashref(cellid);
    $sth->finish();

    my $optData = $Q_Calc->getOptimizationData($dow, $hour, $log);

    $logger->write($log, $DateFunctions->currentTime().": Calculating qHats\n");

    $Q_Calc->Qhat_OpenLog($CurrentDate, $DIR);

    my $opt_cells = 0;

	foreach my $cell_ind (keys(%{$Cell}))
		{
                    ## Signal Indeces
                    my $signal_index = $$Cell{$cell_ind}{'siteid'}.$$Cell{$cell_ind}{'segmentid'}.$hour;
                    my $md_index = $$Cell{$cell_ind}{'san'}."_".$$Cell{$cell_ind}{'siteid'}."_".$$Cell{$cell_ind}{'segmentid'}."_".$$Cell{$cell_ind}{'size'};
	    
                    ## Signal Values
                    my $imp_factor = &impSignal($siteSegSignal, $networkSignal, $signal_index, $hour);
                    my $md_factor = &MDRatio($md_index, $inv_index, $cellMdFactors, $siteSegMdFactors);
			
                    ## LP Index (for show)
                    my $avail_ind = $$Cell{$cell_ind}{'san'}."_".$$Cell{$cell_ind}{'siteid'}."_".$$Cell{$cell_ind}{'segmentid'}."_".$$Cell{$cell_ind}{'size'};
                    my $avail_avg_ind = $$Cell{$cell_ind}{'siteid'}."_".$$Cell{$cell_ind}{'segmentid'}."_".$$Cell{$cell_ind}{'size'};

                    ### QHAT CALC
                    if ($$optData{'availImpressions'}{$md_index}{'capped_volume'} || $$optData{'availImpressionsAvg'}{$avail_avg_ind}{'capped_volume'})
                    {
                        $opt_cells++;
                        my ($qhat, $status) = $Q_Calc->Qhat($Cell, $optData, $cell_ind, $imp_factor, $md_factor);
                        $$Cell{$cell_ind}{'q'} = $qhat;
                        $$Cell{$cell_ind}{'status'} = $status;
                    }
		}
		
    $Q_Calc->Qhat_CloseLog();
    my $net_cells = keys(%{$Cell});
    $logger->write($log, "           >>> $net_cells cells in the network.\n");
    $logger->write($log, "           >>> $opt_cells cells available to optimize.\n");

	open(CELL, ">$DIR/cell.txt");
	    foreach $key (sort keys %{$Cell}) {
	            if ($$Cell{$key}{'status'} eq 'Cell') {
	               print CELL "$$Cell{$key}{'san'}: $$Cell{$key}{'adid'}, $$Cell{$key}{'lp_ind'} -> a = $$Cell{$key}{'actions'}, n = $$Cell{$key}{'impressions'}, q = $$Cell{$key}{'q'}, status = $$Cell{$key}{'status'}\n";
	            }
	    }
	close CELL;
	
	return($Cell);

}

sub GetCostData {
  my ($self, $DIR, $log) = @_;
  my $CurrentDate = $DateFunctions->currentDate;
  
  $logger->write($log, $DateFunctions->currentTime().": Loading cost data\n");


    my $sql = qq|
         SELECT concat(san,"_",siteid,"_",segmentid,"_",size,"_",allocation) as id, allocation as allocation, bid as bid, volume as volume, capped_volume as capped_volume
                FROM PriceVolumeTest
                WHERE allocation < 0.95
         |;  ###DO NOT CONSIDER HIGHEST BID


    my $sth = $dbi->prepare($sql);
    $sth->execute();
    my $cost = $sth->fetchall_hashref(id);
  my $costRows = keys(%{$cost});

    my $sql = qq|
         SELECT concat(siteid,"_",segmentid,"_",size,"_",allocation) as id, allocation as allocation, bid as bid, volume as volume, capped_volume as capped_volume
                FROM PriceVolumeAvg
                WHERE allocation < 0.95
         |;  ###DO NOT CONSIDER HIGHEST BID


    my $sth = $dbi->prepare($sql);
    $sth->execute();
    my $costAvg = $sth->fetchall_hashref(id);
  my $costAvgRows = keys(%{$costAvg});



    $logger->write($log, "           -> $costRows Campaign Level.\n");
    $logger->write($log, "           -> $costAvgRows Site Average.\n");

  return ($cost, $costAvg);
}

sub LP_Obj {
    my ($self, $LP_DIR, $DATA_DIR, $Cell, $cost, $costAvg, $hour, $siteSegSignal, $networkSignal, $cellMaxAlpha, $campaignMaxAlpha, $cellMdFactors, $siteSegMdFactors, $log) = @_;
    
    $logger->write($log, $DateFunctions->currentTime().": Building LP\n");

    open(OBJ, ">$LP_DIR/lp_objective.txt");
    print OBJ "/* Objective Function, expected CVR */\n";
    print OBJ "max:\n";
    
    open(BOUND, ">$LP_DIR/lp_bounds.txt");
    print BOUND "/* LP BOUNDS */\n";
    #print BOUND "/* Placement MAX ALLOCATION */\n";
    
    open(MINS, ">$DATA_DIR/noCostMins.csv");
    print MINS "cell,lp_var,baseCoeff\n";

    my %OBJ = (); ## New OBJ Hash
    %BudgetConstraint = (); ## New Budget Hash
    my %MaxAlpha = ();
    #my $noCostMinBids = {};

    foreach $key (sort keys %{$Cell}) {
        my $espend;
        my $evolume;
        $$Cell{$key}{'segmentid'} =~ s/-/neg/g;
        my $lp_var_main = $$Cell{$key}{'san'}."_".$$Cell{$key}{'adid'}."_".$$Cell{$key}{'siteid'}."_".$$Cell{$key}{'segmentid'}."_".$$Cell{$key}{'size'};
        my $inv_index = $$Cell{$key}{'siteid'}."_".$$Cell{$key}{'segmentid'}."_".$$Cell{$key}{'size'};
        my $pv_index = $$Cell{$key}{'san'}."_".$$Cell{$key}{'siteid'}."_".$$Cell{$key}{'segmentid'}."_".$$Cell{$key}{'size'}."_".&MaxAlpha($lp_var_main, $$Cell{$key}{'san'}, $cellMaxAlpha, $campaignMaxAlpha);
        my $pv_avg_index = $$Cell{$key}{'siteid'}."_".$$Cell{$key}{'segmentid'}."_".$$Cell{$key}{'size'}."_".&MaxAlpha($lp_var_main, $$Cell{$key}{'san'}, $cellMaxAlpha, $campaignMaxAlpha);
        my $signal_index = $$Cell{$key}{'siteid'}.$$Cell{$key}{'segmentid'}.$hour;
        my $md_index = $$Cell{$key}{'san'}."_".$$Cell{$key}{'siteid'}."_".$$Cell{$key}{'segmentid'}."_".$$Cell{$key}{'size'};
        
        ## Calc Cost Based on Campaign PV Avail or Avg PV Avail
        if ($$cost{$pv_index})
        {
            $espend = $$cost{$pv_index}{'bid'} * $$cost{$pv_index}{'capped_volume'} * 0.001;
            $evolume = $$cost{$pv_index}{'capped_volume'};
        }
        elsif ($$costAvg{$pv_avg_index})
        {
            $espend = $$costAvg{$pv_avg_index}{'bid'} * $$costAvg{$pv_avg_index}{'capped_volume'} * 0.001;
            $evolume = $$costAvg{$pv_avg_index}{'capped_volume'};
        }
        else
        {
            $espend = 0;
            $evolume = 0;
        }

        if ($espend > 0)
        {
            my $imp_factor = &impSignal($siteSegSignal, $networkSignal, $signal_index, $hour);
            my $md_factor = &MDRatio($md_index, $inv_index, $cellMdFactors, $siteSegMdFactors);
            my $obj_value = $$Cell{$key}{'q'} * $evolume * $imp_factor * $md_factor;
            
            if ($obj_value > 0)
            {
                $OBJ{$inv_index}{$lp_var_main}{'coeff'} = $obj_value;
                $BudgetConstraint{$$Cell{$key}{'san'}}{$lp_var_main}{'coeff'} = $espend * $imp_factor * $md_factor;
                $MaxAlpha{$$Cell{$key}{'san'}}{$inv_index}{$lp_var_main} = 1;
            }
        }
        else
        {
            #$$noCostMinBids{$lp_var_main}{'cellId'} = $key;
            print MINS "$key,$$Cell{$key}{'san'},$lp_var_main,$espend\n";
        }
    }

    foreach $ii (sort keys %OBJ) {
        foreach $lp_name (sort keys %{$OBJ{$ii}}) {
            print OBJ "+ ".$OBJ{$ii}{$lp_name}{'coeff'}." ".$lp_name."\n";
            #print BOUND "+ ".$lp_name."\n";
        }
        #print BOUND "<=1;\n\n";
    }

    print BOUND "/* Max ALLOCATIONS (default ($max_alpha_default), and Campaign Level) */\n";
    foreach $san (sort keys %MaxAlpha) {
        foreach $site (sort keys %{$MaxAlpha{$san}}) {
            my $cell_count = 0;
            foreach $cell (sort keys %{$MaxAlpha{$san}{$site}}) {
                if(!$$cellMaxAlpha{$cell}) {
                    $cell_count++;
                    print BOUND "+ $cell\n";
                }
            }
            if ($cell_count > 0) {
                if ($$campaignMaxAlpha{$san}) {
                    print BOUND "<= $$campaignMaxAlpha{$san}{'allocation'};\n\n";
                }
                else {
                    print BOUND "<= $max_alpha_default;\n\n";
                }
            }
        }
    }

    print BOUND "/* Cell Level Max ALLOCATIONS */\n";
    foreach $cell (sort keys %{$cellMaxAlpha}) {
        print BOUND "+ $cell <= $$cellMaxAlpha{$cell}{'allocation'};\n\n";
    }


    print OBJ ";\n\n";

    close OBJ;
    close BOUND;
    close VALS;
    %OBJ = ();
    %MaxAlpha = ();

    $logger->write($log, "           -> Objective and Bounds set\n");

#return($noCostMinBids);

}

sub LP_Constraint {
  my ($self, $DIR, $hour, $campConfig, $campaignBudgetSignal, $networkBudgetSignal, $log) = @_;
  my $CurrentDate = $DateFunctions->currentDate;
  

open(CONST, ">$DIR/lp_constraint.txt");
print CONST "/* CONSTRAINTS: Daily Budget */\n";

  foreach $san (keys %{$campConfig}) {
          foreach $lpvar (sort keys %{$BudgetConstraint{$san}}) {
                  print CONST "+ ".$BudgetConstraint{$san}{$lpvar}{'coeff'}." ".$lpvar."\n";
          }
        if ( keys (%{$BudgetConstraint{$san}}) > 0 ) ### If no cells for san, no constraint
        	{
        		my $budgetAmount = &greaterOf(1, $$campConfig{$san}{'totalbudget'} * &budgetSignal($campaignBudgetSignal, $networkBudgetSignal, $san, $hour));
          		print CONST "<= $budgetAmount;\n\n";
      		}
  }
close CONST;
%BudgetConstraint = ();

	$logger->write($log, "           -> Budget Constraint set\n");
}

sub LP_Build {
  my($self, $DIR, $log) = @_;
  $logger->write($log, $DateFunctions->currentTime().": Assembling main LP\n");
  
  #my $cmd = "copy $DIR\\lp_objective.txt + $DIR\\lp_constraint.txt + $DIR\\lp_bounds.txt $DIR\\lp_main.lp";
  my $cmd = "cat $DIR/lp_objective.txt $DIR/lp_constraint.txt $DIR/lp_bounds.txt > $DIR/lp_main.lp";
  
  system($cmd);

}

sub LP_Solve {
  my ($self, $DIR, $log) = @_;
  $logger->write($log, $DateFunctions->currentTime().": solving LP...\n");
  my $cmd = "/home/ec2-user/bin/lp_solve/lp_solve -S $DIR/lp_main.lp > $DIR/lp_solution.txt";

  system($cmd);

  $logger->write($log, $DateFunctions->currentTime().": LP solved.\n");

}

sub BidCalc {
  my ($self, $LP_DIR, $BIDS_DIR, $Cell, $bidMap, $bidMapAvg, $siteSegSignal, $networkSignal, $dow, $hour, $cellMdFactors, $siteSegMdFactors, $log) = @_;
  my $CurrentDate = $DateFunctions->currentDate;
  $logger->write($log, $DateFunctions->currentTime().": Calculating Bids\n");
  $logger->write($log, "           -> ".keys(%{$bidMap})." bids in map.\n");
  $logger->write($log, "           -> ".keys(%{$bidMapAvg})." bids in AVG map.\n");

open (BIDMAP, ">$BIDS_DIR/bid_map.txt");
    foreach $key (sort keys %{$bidMap}) {
    	$$bidMap{$key}{'allocation'} = sprintf("%.2f", $$bidMap{$key}{'allocation'});
      	$$bidMap{$key}{'evolume'} = $$bidMap{$key}{'allocation'} * $$bidMap{$key}{'volume'};
      	$$bidMap{$key}{'capped_evolume'} = $$bidMap{$key}{'allocation'} * $$bidMap{$key}{'capped_volume'};
      	$$bidMap{$key}{'bid'} = sprintf("%.2f", $$bidMap{$key}{'bid'});
    		
        print BIDMAP "$key: bid = $$bidMap{$key}{'bid'}\n";
    }
close BIDMAP;


  open(IN, "$LP_DIR/lp_solution.txt");
  my $line = 0;
  my $optBids = {};
  while(<IN>) {
    $line++;

    my $alloc;
    my @sol;
    my $file_line = $_;
    if ($line > 5) {
      if($file_line =~ m/0\./) {
            $file_line =~ s/0\./-/g;
            $file_line =~ s/\s//g;
            @sol = split(/-/, $file_line);
            my $ap = "0.".$sol[1];
                 my $offset_alloc = nearest(0.05, sprintf("%.2f", ($ap)));
                 $alloc = sprintf("%.2f", $Q_Calc->isGreater(0, $offset_alloc));
      }
      else {
           @sol = split(/\s\s\s\s\s\s\s\s\s\s\s\s/, $file_line);
           my $ap = "0.".$sol[1];
           my $offset_alloc = nearest(0.05, sprintf("%.2f", ($ap)));
           $alloc = sprintf ("%.2f", $Q_Calc->isGreater(0, $offset_alloc));
      }

      my @sss = split(/\_/, $sol[0]);
      my $segid = $sss[3]; $segid =~ s/neg/-/g;
      my $pv_ind = $sss[0]."_".$sss[2]."_".$segid."_".$sss[4]."_".$alloc;
      my $inv_index = $sss[2]."_".$sss[3]."_".$sss[4];
      my $signal_index = $sss[2].$sss[3].$hour;

      my $bid;
      my $volume;
      my $capped_volume;
      my $espend;
      if($alloc eq '0' || $alloc == 0) {
         $bid = $min_bid;
         $volume = 0;
         $capped_volume = 0;
         $espend = 0;
      }
      else {
      	my $imp_factor = &impSignal($siteSegSignal, $networkSignal, $signal_index, $hour);
      	my $md_factor = &MDRatio($sol[0], $inv_index, $cellMdFactors, $siteSegMdFactors);
        if ($$bidMap{$pv_ind})
        {
            $bid = $$bidMap{$pv_ind}{'bid'};
            $volume = $$bidMap{$pv_ind}{'evolume'} * $imp_factor * $md_factor;
            $capped_volume = $$bidMap{$pv_ind}{'capped_evolume'} * $imp_factor * $md_factor;
        }
        elsif ($$bidMapAvg{$inv_index})
        {
            $bid = $$bidMapAvg{$inv_index}{'bid'};
            $volume = $$bidMapAvg{$inv_index}{'evolume'} * $imp_factor * $md_factor;
            $capped_volume = $$bidMapAvg{$inv_index}{'capped_evolume'} * $imp_factor * $md_factor;
        }
        
        if (!defined $bid || $bid == 0 || $bid eq '') { $bid = $min_bid; $volume = 0; $capped_volume = 0; }
        $espend = ($bid*$capped_volume)/1000;
      }

      $$optBids{$sol[0]}{'bid'} = $bid;
      $$optBids{$sol[0]}{'allocation'} = $alloc;
      $$optBids{$sol[0]}{'evolume'} = $volume;
      $$optBids{$sol[0]}{'capped_evolume'} = $capped_volume;
      $$optBids{$sol[0]}{'espend'} = $espend;
    }
  }
my $bidMap = {};

open(BIDS, ">$BIDS_DIR/optBids.csv");
    print BIDS "Id,San,Cell,Bid,Allocation,EImps(total avail),EImps(capped),ESpend,BidType\n";

open(DEFBIDS, ">$BIDS_DIR/defBids.csv");
    print DEFBIDS "Id,San,Cell,Bid\n";

  my $defBids = {};
		my $ac = new apiConfig;
		foreach $cell (sort keys %{$Cell})
			{
				my $lp_var = $$Cell{$cell}{'san'}."_".$$Cell{$cell}{'adid'}."_".$$Cell{$cell}{'siteid'}."_".$$Cell{$cell}{'segmentid'}."_".$$Cell{$cell}{'size'};
				if ($$optBids{$lp_var})
					{
						$$optBids{$lp_var}{'type'} = "CDO";
						$$optBids{$lp_var}{'cellId'} = $cell;
						
                                                print BIDS "$cell,$$Cell{$cell}{'san'},$lp_var,$$optBids{$lp_var}{'bid'},$$optBids{$lp_var}{'allocation'},$$optBids{$lp_var}{'evolume'},$$optBids{$lp_var}{'capped_evolume'},$$optBids{$lp_var}{'espend'},$$optBids{$lp_var}{'type'}\n";
					}
				else
					{
						#$$defBids{$lp_var}{'cellId'} = $cell;
                                                $$defBids{$lp_var}{'bid'} = $ac->getCommonParam('minBid');

                                                print DEFBIDS "$cell,$$Cell{$cell}{'san'},$lp_var,$$defBids{$lp_var}{'bid'}\n";
					}
			}
  
### If No LP Solution >> Exit and notify!
	if ($line == 0)
		{
			my $hostname = $ENV{'COMPUTERNAME'};
			my $subject = "CDO ERROR! ($hostname)";
			my $message = "CDO failed before bids were caluclated!\n-> LP Error: NO LP solution.\n";
			$notify->send_email("mpatton\@doublepositive.com", "cdo\@doublepositive.com", $subject, $message, 0, '');
			
			exit;
		}
  
  my $num_bids = keys(%{$optBids});
  $logger->write($log, "           -> $num_bids cells with optimized bids.\n");
  $logger->write($log, "           -> ".keys(%{$defBids})." cells with default bids.\n");

close BIDS;
close DEFBIDS;
close IN;

return($optBids);

}

sub processBids {

    my ($self, $bidList, $date, $lastDate, $hour, $lastHour, $log) = @_;
    $logger->write($log, $DateFunctions->currentTime().": Processing Bids\n"); 
    
    my @bidTypes = split(/\s/, apiConfig->getCommonParam('bidTypes'));
    
    foreach my $bt (@bidTypes)
    {
        bidOps->getBids($bt, $bidList, $date, $lastDate, $hour, $lastHour, $log);
    }

    $logger->write($log, $DateFunctions->currentTime().": Done Processing Bids.\n");
}


#### LOCAL SUBS
sub MaxAlpha {
 my($cell, $san, $cellMaxAlpha, $campaignMaxAlpha) = @_;
 my $max_alpha;

    if ($$cellMaxAlpha{$cell}) {
       $max_alpha = $$cellMaxAlpha{$cell}{'allocation'};
    }
    elsif ($$campaignMaxAlpha{$san}) {
       $max_alpha = $$campaignMaxAlpha{$san}{'allocation'};
    }
    else {
       $max_alpha = $max_alpha_default;
    }

 return $max_alpha;

}

sub MDRatio {
 my($md_ind, $inv_ind, $cellMdFactors, $siteSegMdFactors) = @_;
 my $ratio;
 
    if ($$cellMdFactors{$md_ind}{'ratio'}) {
       $ratio = $$cellMdFactors{$md_ind}{'ratio'};
    }
    elsif ($$siteSegMdFactors{$inv_ind}{'ratio'}) {
       $ratio = $$siteSegMdFactors{$inv_ind}{'ratio'};
    }
    else {
       $ratio = 1;
    }
    
 return $ratio;

}

sub noNull {
	my ($input, $output) = @_;

	if ($input > 0)
		{
			return $input;	
		}
	else
		{
			return $output;
		}
}

sub ifExists {
	my ($input, $output) = @_;

	if ($input ne '')
		{
			return $input;	
		}
	else
		{
		        return $output;
		}
}

sub impSignal {
	my ($s, $n, $input, $hour) = @_;
	my $factor;
	
	if ($$s{$input})
		{
                    if ($$s{$input}{'total_imps'} == 0)
                    {
                        $factor = $$n{$hour}{'hour_imps'}/$$n{$hour}{'total_imps'};
                    }
                    else
                    {
			$factor = $$s{$input}{'hour_imps'}/$$s{$input}{'total_imps'};
                    }
		}
	else
		{
			$factor = $$n{$hour}{'hour_imps'}/$$n{$hour}{'total_imps'};
		}
	
	return $factor;
}

sub budgetSignal {
	my ($b, $n, $input, $hour) = @_;
	my $factor;
	my $key = $input.$hour;
	
	if($$b{$key}{'total_actions'} > 24)
	{
		if ($$b{$key} == 0)
		{
			$factor = 0.0000001;
		}
		else
		{
			$factor = $$b{$key}{'hour_actions'}/$$b{$key}{'total_actions'};
		}
		
	}
	else
	{
		$factor = $$n{$hour}{'hour_actions'}/$$n{$hour}{'total_actions'};	
	}
	
	return $factor;
}

sub greaterOf
{
	my ($a, $b) = @_;
	
	if ($b > $a)
		{
			return $b;
		}
	else
		{
			return $a;
		}
}

1;
