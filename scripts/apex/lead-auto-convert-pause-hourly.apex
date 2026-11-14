for (CronTrigger c : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = 'Lead Auto-Convert hourly check']) { System.abortJob(c.Id); System.debug('ABORTED=' + c.Id); }
